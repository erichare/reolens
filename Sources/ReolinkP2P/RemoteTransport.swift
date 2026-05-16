import Foundation
import OSLog
import ReolinkBaichuan
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "remote-transport")

/// `BcMessageTransport` conformance that ferries Baichuan
/// messages over the Reolink P2P data plane. Counterpart to
/// `LANTransport` for the off-LAN path.
///
/// ## State machine (per `connect()` call)
///
/// 1. **Discovery.** `P2PDiscovery.lookup(uid:)` against the
///    `p2p*.reolink.com` cluster. Returns the camera's current
///    WAN registration plus a relay endpoint.
/// 2. **Hole-punch.** `HolePunchScheduler.punch(...)` probes
///    registration first, falls back to relay if it doesn't
///    respond within `directDeadline` (6 s by default per
///    decision #2). Returns the winning endpoint + the path
///    discriminator (direct vs relayed) for UI.
/// 3. **Data channel.** `dataConnectionFactory` builds a
///    `BcUdpDataConnection` bound to the winning endpoint.
///    Subsequent sends/receives flow through that connection.
/// 4. **Send path.** Baichuan messages are encoded with the
///    current cipher, fragmented to fit MTU via
///    `DataFragmenter`, and stamped as `BcUdpDataPacket`s.
/// 5. **Receive path.** Inbound `BcUdpDataPacket`s feed a
///    `DataReassembler`; once a complete Baichuan message
///    surfaces it's routed to the matching reply slot or
///    broadcast to subscribers.
///
/// ## Status (Phase 3d.2, partial)
///
/// What this commit ships:
/// - Discovery + hole-punch are wired through and gated on
///   injected `HolePunchProbeRunner` + endpoint-keyed factory.
///   `connect()` succeeds when a winning candidate is selected.
/// - `nextMessageNumber`, `currentCipher`, `setCipher`,
///   `close` behave correctly.
///
/// Still pending Phase 3d.2-D + 3d.2-F:
/// - `sendAndAwait` runs `DataFragmenter` to split the message
///   bytes but the actual UDP send + receive-loop reassembly
///   path isn't wired yet (concrete
///   `NWConnectionBcUdpDataConnection` is the missing piece).
///   It still throws `notYetImplemented` so callers (notably
///   `CameraSession`) don't silently swallow the gap.
/// - `subscribe()` returns an immediately-finished stream
///   until the receive loop lands.
public actor RemoteTransport: BcMessageTransport {

    public let credentials: BaichuanCredentials
    public let uid: String

    private let discovery: P2PDiscovery
    private let probeRunner: any HolePunchProbeRunner
    private let dataConnectionFactory: @Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection
    private let directDeadline: Duration
    private let relayDeadline: Duration

    private var dataConnection: (any BcUdpDataConnection)?
    private var winner: HolePunchResult?
    private var fragmenter: DataFragmenter?
    private var cipher: BcCipher = .unencrypted
    private var nextMsgNum: UInt16 = 0
    private var isClosed = false

    /// Locally-minted connection ID stamped into outbound
    /// `BcUdpDataPacket`s. The wire capture showed each
    /// session uses its own connection ID minted somewhere in
    /// the handshake; absent a clear signal of where it comes
    /// from, we generate it locally for now. Phase 3d.2-D
    /// can swap to a handshake-provided ID once we have
    /// captures showing how the server advertises one.
    private let connectionID: UInt32

    /// - Parameters:
    ///   - credentials: Baichuan login credentials. The
    ///     username/password gate the Baichuan-layer login
    ///     that runs on top of this transport; they're not used
    ///     for discovery (which is UID-keyed) or hole-punch.
    ///   - uid: Camera UID, captured on first LAN login and
    ///     persisted in `CameraEntry.uid` (Phase 4b).
    ///   - discovery: `p2p*.reolink.com` discovery actor.
    ///   - probeRunner: Sends Disc probes to candidates during
    ///     hole-punch. Production wraps a real UDP socket;
    ///     tests inject a scripted runner.
    ///   - dataConnectionFactory: Builds the post-punch data
    ///     channel bound to the winning endpoint. Called once,
    ///     after the scheduler picks a winner.
    ///   - directDeadline: How long to wait for the
    ///     registration (direct) probe before falling back to
    ///     relay. Decision #2 fixes the production value at 6
    ///     s.
    ///   - relayDeadline: How long to wait for the relay probe
    ///     before declaring exhaustion. 4 s is conservative —
    ///     a relay path that won't respond quickly is likely
    ///     broken regardless.
    ///   - connectionID: Optional override. Tests pin to a
    ///     known value; production lets the actor mint one.
    public init(
        credentials: BaichuanCredentials,
        uid: String,
        discovery: P2PDiscovery,
        probeRunner: any HolePunchProbeRunner,
        dataConnectionFactory: @escaping @Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection,
        directDeadline: Duration = .seconds(6),
        relayDeadline: Duration = .seconds(4),
        connectionID: UInt32? = nil
    ) {
        self.credentials = credentials
        self.uid = uid
        self.discovery = discovery
        self.probeRunner = probeRunner
        self.dataConnectionFactory = dataConnectionFactory
        self.directDeadline = directDeadline
        self.relayDeadline = relayDeadline
        self.connectionID = connectionID ?? UInt32.random(in: 1...UInt32.max)
    }

    // MARK: - BcMessageTransport

    public func connect() async throws {
        guard dataConnection == nil else { return }
        log.info("RemoteTransport.connect uid=\(self.uid, privacy: .private)")

        // Discovery first.
        let candidates: DiscoveryXML.LookupResponse
        do {
            candidates = try await discovery.lookup(uid: uid)
        } catch {
            log.error("Discovery failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if candidates.isEmpty {
            throw RemoteTransportError.noCandidates(uid: uid)
        }

        // Hole-punch.
        let result: HolePunchResult
        do {
            result = try await HolePunchScheduler.punch(
                candidates,
                directDeadline: directDeadline,
                relayDeadline: relayDeadline,
                runner: probeRunner
            )
        } catch HolePunchError.allFailed {
            throw RemoteTransportError.holePunchExhausted(
                uid: uid,
                deadline: directDeadline + relayDeadline
            )
        } catch HolePunchError.noCandidates {
            throw RemoteTransportError.noCandidates(uid: uid)
        } catch {
            throw error
        }

        log.info("Hole-punch winner: \(result.endpoint.host, privacy: .private):\(result.endpoint.port, privacy: .public) path=\(String(describing: result.path), privacy: .public)")

        // Bind the data channel to the winner.
        let channel = try await dataConnectionFactory(result.endpoint)
        try await channel.connect()
        self.dataConnection = channel
        self.winner = result
        self.fragmenter = DataFragmenter(connectionID: connectionID)
        log.info("RemoteTransport data channel ready uid=\(self.uid, privacy: .private)")
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let channel = dataConnection {
            await channel.close()
        }
        dataConnection = nil
        winner = nil
        fragmenter = nil
    }

    public func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval,
        stage: String
    ) async throws -> BcMessage {
        guard dataConnection != nil, fragmenter != nil else {
            throw RemoteTransportError.notYetImplemented(
                detail: "connect() must succeed before sendAndAwait can run"
            )
        }
        // Fragmentation is already wire-correct (Phase 3d.2-B).
        // What's still missing is the receive loop that ingests
        // inbound Data packets, runs them through
        // DataReassembler, parses BcMessages, and routes them
        // to reply slots. That's Phase 3d.2-F (next commit) and
        // depends on the concrete
        // `NWConnectionBcUdpDataConnection` from 3d.2-D
        // actually delivering inbound packets to subscribers.
        _ = (message, timeout, stage)
        throw RemoteTransportError.notYetImplemented(
            detail: "send-path fragmenter is wired; receive loop awaits Phase 3d.2-F"
        )
    }

    public func subscribe() async -> AsyncStream<BcMessage> {
        AsyncStream { continuation in
            // Phase 3d.2-F replaces this with a bridge from the
            // reassembler's BcMessage output. Until then, no
            // events flow to subscribers.
            continuation.finish()
        }
    }

    public func nextMessageNumber() -> UInt16 {
        let n = nextMsgNum
        nextMsgNum &+= 1
        return n
    }

    public func currentCipher() -> BcCipher { cipher }
    public func setCipher(_ new: BcCipher) { self.cipher = new }

    // MARK: - Inspection (for diagnostics / tests)

    /// The path the hole-punch landed on, once `connect()`
    /// has succeeded. `nil` before the punch completes or
    /// after `close()`.
    public var connectionPath: HolePunchResult.Path? {
        winner?.path
    }
}

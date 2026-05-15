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
/// 1. Run `P2PDiscovery.lookup(uid:)` against the
///    `p2p*.reolink.com` cluster. Returns up to four candidates:
///    WAN-v4, WAN-v6, LAN-v4, relay.
/// 2. Send BcUdp `Disc` probes to every direct candidate
///    simultaneously. The first 5-tuple to round-trip an `Ack`
///    becomes the data channel.
/// 3. If no direct candidate responds within a deadline
///    (decision #2 in `docs/0.7.0-plan.md` → 6 seconds), fall
///    back to the relay candidate. No opt-out (decision #4).
/// 4. Hand the resulting socket to a `BcUdpDataConnection` and
///    forward Baichuan messages over it (encoding/decoding +
///    reassembly via `BcUdpDataPacket`).
/// 5. Run a keepalive loop (~10 s) so the NAT mapping survives.
///
/// ## Status
///
/// **Phase 3d.1 — skeleton.** The structural shell, factory
/// wiring, and protocol conformance land here so the
/// reachability state machine in Phase 3e can compile against
/// the type. The hole-punch state machine itself is gated on
/// real-device tcpdump validation of the BcUdp magic constants
/// (`Sources/ReolinkBcUdp/Wire/BcUdpConstants.swift`) and the
/// discovery XML tag names. Until then, `connect()` throws
/// `RemoteTransportError.notYetImplemented`.
///
/// This means: a user off-LAN today sees the same observable
/// behaviour as before remote work began ("Camera offline").
/// What we've shipped is the *plumbing* — Phase 4b ensures the
/// UID is captured, Phase 3e wires the fallback decision tree
/// to attempt remote, and Phase 3d.2 will replace the throw
/// with a working hole-punch once we can capture a real
/// `p2p*.reolink.com` exchange to validate the magics.
///
/// ## Dependencies (injected for testability)
///
/// `connect()` consumes two collaborators that the tests stub:
///
/// - `discovery: P2PDiscovery` — already actor-isolated and
///   transport-injectable (Phase 2).
/// - `dataConnectionFactory: (LookupResponse) async throws ->
///   any BcUdpDataConnection` — a closure that builds the
///   stateful data channel given a discovery result. In
///   production this resolves to
///   `NWConnectionBcUdpDataConnection` (Phase 3d.2); in tests
///   it returns a scripted stub.
public actor RemoteTransport: BcMessageTransport {

    public let credentials: BaichuanCredentials
    public let uid: String

    private let discovery: P2PDiscovery
    private let dataConnectionFactory: @Sendable (DiscoveryXML.LookupResponse) async throws -> any BcUdpDataConnection
    private let holePunchDeadline: Duration

    private var dataConnection: (any BcUdpDataConnection)?
    private var cipher: BcCipher = .unencrypted
    private var nextMsgNum: UInt16 = 0
    private var isClosed = false

    /// - Parameters:
    ///   - credentials: Baichuan login credentials. Same shape
    ///     as `LANTransport`; the username/password gate the
    ///     Baichuan login that runs on top of this transport,
    ///     not the discovery layer (which is UID-keyed).
    ///   - uid: The camera's Reolink-assigned UID, captured on
    ///     first LAN login via `BaichuanClient.fetchUID(...)`
    ///     and persisted in `CameraEntry.uid` (Phase 4b).
    ///   - discovery: Discovery actor configured against the
    ///     `p2p*.reolink.com` cluster. Inject for tests.
    ///   - dataConnectionFactory: Builds the post-punch data
    ///     channel from a discovery result. Inject for tests.
    ///   - holePunchDeadline: Wall-clock deadline before
    ///     falling back from direct candidates to the relay.
    ///     Decision #2 fixes the production value at 6 s; tests
    ///     pass smaller values for fast-failure paths.
    public init(
        credentials: BaichuanCredentials,
        uid: String,
        discovery: P2PDiscovery,
        dataConnectionFactory: @escaping @Sendable (DiscoveryXML.LookupResponse) async throws -> any BcUdpDataConnection,
        holePunchDeadline: Duration = .seconds(6)
    ) {
        self.credentials = credentials
        self.uid = uid
        self.discovery = discovery
        self.dataConnectionFactory = dataConnectionFactory
        self.holePunchDeadline = holePunchDeadline
    }

    // MARK: - BcMessageTransport

    public func connect() async throws {
        guard dataConnection == nil else { return }
        log.info("RemoteTransport.connect uid=\(self.uid, privacy: .private)")

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

        let channel = try await dataConnectionFactory(candidates)
        try await channel.connect()
        self.dataConnection = channel
        log.info("RemoteTransport data channel ready uid=\(self.uid, privacy: .private)")
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let channel = dataConnection {
            await channel.close()
        }
        dataConnection = nil
    }

    public func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval,
        stage: String
    ) async throws -> BcMessage {
        // Phase 3d.2 turns this into a real BcUdp Data send +
        // ack-tracked reassembly of the reply. The skeleton
        // surfaces the unimplemented state so Phase 3e can wire
        // the reachability state machine without crashing.
        _ = (message, timeout, stage)
        throw RemoteTransportError.notYetImplemented(detail: "sendAndAwait awaits Phase 3d.2 hole-punch + reassembly wiring")
    }

    public func subscribe() async -> AsyncStream<BcMessage> {
        AsyncStream { continuation in
            // No data channel yet — return an empty stream that
            // immediately finishes. Callers iterate with `for
            // await` and see no events, matching the
            // "transport not yet active" observable state.
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
}

// MARK: - Convenience for callers

extension RemoteTransport {

    /// Build a `RemoteTransport` paired with a default
    /// `P2PDiscovery` configured against the production
    /// server pool. The data-connection factory still has to be
    /// supplied because the only production conformer
    /// (`NWConnectionBcUdpDataConnection`) lands in Phase 3d.2.
    public static func production(
        credentials: BaichuanCredentials,
        uid: String,
        bcUdpTransport: any BcUdpTransport,
        dataConnectionFactory: @escaping @Sendable (DiscoveryXML.LookupResponse) async throws -> any BcUdpDataConnection
    ) -> RemoteTransport {
        RemoteTransport(
            credentials: credentials,
            uid: uid,
            discovery: P2PDiscovery(transport: bcUdpTransport),
            dataConnectionFactory: dataConnectionFactory
        )
    }
}

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
///    `p2p*.reolink.com` cluster — returns the camera's
///    current WAN registration plus a relay endpoint.
/// 2. **Hole-punch.** `HolePunchScheduler.punch(...)` probes
///    registration first, falls back to relay on timeout.
/// 3. **Data channel.** `dataConnectionFactory` builds a
///    `BcUdpDataConnection` bound to the winning endpoint.
/// 4. **Receive loop.** A child task subscribes to the data
///    connection's inbound stream, runs each `BcUdpDataPacket`
///    through a `DataReassembler`, and parses out `BcMessage`s
///    using the Baichuan layer's own decode.
/// 5. **Send.** `sendAndAwait` encodes a `BcMessage` with the
///    negotiated cipher, fragments via `DataFragmenter`, and
///    writes each fragment to the data connection.
///
/// ## Status (Phase 3d.2)
///
/// Discovery, hole-punch, fragment codec, and receive loop
/// are all wired through with offline tests covering the
/// flow. The remaining piece is the concrete UDP layer
/// (`NWConnectionBcUdpDataConnection`) — until that lands,
/// production callers will need to inject a real UDP-backed
/// `BcUdpDataConnection` themselves; unit tests use the
/// stubbed connection in `RemoteTransportTests`.
public actor RemoteTransport: BcMessageTransport {

    public let credentials: BaichuanCredentials
    public let uid: String

    private let discovery: P2PDiscovery
    private let rendezvous: RendezvousClient
    private let probeRunner: any HolePunchProbeRunner
    private let dataConnectionFactory: @Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection
    private let directDeadline: Duration
    private let relayDeadline: Duration

    /// Server-assigned session ID from the rendezvous reply.
    /// Stored so future commits can stamp it into the
    /// `C2D_T` punch probe payload (Phase 3d.2 finish).
    private var sessionID: UInt32?

    private var dataConnection: (any BcUdpDataConnection)?
    private var winner: HolePunchResult?
    private var fragmenter: DataFragmenter?
    private var reassembler: DataReassembler?
    private var receiveTask: Task<Void, Never>?
    private var readBuffer: Data = Data()
    private var cipher: BcCipher = .unencrypted
    private var nextMsgNum: UInt16 = 0
    private var isClosed = false

    /// Reply slots keyed by `msg_num` — same pattern as
    /// `LANTransport`. Registered synchronously inside the
    /// actor before the send is dispatched, so a fast reply
    /// can't slip through to subscribers.
    private var replySlots: [UInt16: AsyncStream<BcMessage>.Continuation] = [:]

    /// Subscribers that consume the unsolicited-message stream
    /// (events, server-initiated pushes).
    private var unsolicitedContinuations: [UUID: AsyncStream<BcMessage>.Continuation] = [:]

    /// Locally-minted connection ID stamped into outbound
    /// `BcUdpDataPacket`s. Phase 3d.2-D may swap to a
    /// handshake-provided value if the protocol turns out to
    /// hand one over.
    private let connectionID: UInt32

    public init(
        credentials: BaichuanCredentials,
        uid: String,
        discovery: P2PDiscovery,
        rendezvous: RendezvousClient,
        probeRunner: any HolePunchProbeRunner,
        dataConnectionFactory: @escaping @Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection,
        directDeadline: Duration = .seconds(6),
        relayDeadline: Duration = .seconds(4),
        connectionID: UInt32? = nil
    ) {
        self.credentials = credentials
        self.uid = uid
        self.discovery = discovery
        self.rendezvous = rendezvous
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

        // Step 1: Discovery — find the rendezvous server.
        let lookup: DiscoveryXML.LookupResponse
        do {
            lookup = try await discovery.lookup(uid: uid)
        } catch {
            log.error("Discovery failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if lookup.isEmpty {
            throw RemoteTransportError.noCandidates(uid: uid)
        }
        guard let rendezvousEndpoint = lookup.rendezvous else {
            // Discovery succeeded but didn't return a
            // rendezvous endpoint — can't proceed.
            throw RemoteTransportError.noCandidates(uid: uid)
        }
        guard let relayHint = lookup.relay else {
            // The rendezvous request requires a relay hint;
            // if discovery omitted one we have no preferred
            // fallback to advertise. Surface as no-candidates
            // since the camera is effectively unreachable.
            throw RemoteTransportError.noCandidates(uid: uid)
        }

        // Step 2: Rendezvous — get the camera's `<dmap>`
        // (NAT'd public address) and a server-assigned
        // session ID.
        let rendezvousReply: DiscoveryXML.RendezvousReply
        do {
            rendezvousReply = try await rendezvous.rendezvous(
                uid: uid,
                rendezvousEndpoint: rendezvousEndpoint,
                relayHint: relayHint,
                connectionID: connectionID
            )
        } catch RendezvousError.serverRejected(let code) {
            log.warning("Rendezvous server rejected: code=\(code, privacy: .public)")
            throw RemoteTransportError.noCandidates(uid: uid)
        } catch {
            log.error("Rendezvous failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.sessionID = rendezvousReply.sessionID

        // Step 3: Hole-punch. Probe the camera's `<dmap>`
        // (direct path) with the rendezvous reply's relay (or
        // discovery's relay as backup) as fallback.
        let punchRelay = rendezvousReply.relay ?? relayHint
        let result: HolePunchResult
        do {
            result = try await HolePunchScheduler.punch(
                direct: rendezvousReply.deviceMappedEndpoint,
                relay: punchRelay,
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

        log.info("Hole-punch winner: \(result.endpoint.host, privacy: .private):\(result.endpoint.port, privacy: .public) path=\(String(describing: result.path), privacy: .public) sid=\(rendezvousReply.sessionID, privacy: .public)")

        // Step 4: Hand off to the data channel.
        let channel = try await dataConnectionFactory(result.endpoint)
        try await channel.connect()
        self.dataConnection = channel
        self.winner = result
        self.fragmenter = DataFragmenter(connectionID: connectionID)
        self.reassembler = DataReassembler(connectionID: connectionID)

        startReceiveLoop()
        log.info("RemoteTransport ready uid=\(self.uid, privacy: .private)")
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        if let channel = dataConnection {
            await channel.close()
        }
        dataConnection = nil
        winner = nil
        fragmenter = nil
        reassembler = nil
        sessionID = nil
        readBuffer = Data()
        for (_, cont) in replySlots {
            cont.finish()
        }
        replySlots.removeAll()
        for (_, cont) in unsolicitedContinuations {
            cont.finish()
        }
        unsolicitedContinuations.removeAll()
    }

    public func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval,
        stage: String
    ) async throws -> BcMessage {
        guard let dataConnection,
              var fragmenter = self.fragmenter else {
            throw RemoteTransportError.notYetImplemented(
                detail: "connect() must succeed before sendAndAwait"
            )
        }

        let msgNum = message.header.msgNum
        let bytes = message.encode(cipher: cipher)
        let fragments = fragmenter.fragment(bytes)
        self.fragmenter = fragmenter

        // Register the reply slot BEFORE sending so a fast
        // reply can't fall through to subscribers.
        let (stream, continuation) = AsyncStream<BcMessage>.makeStream(bufferingPolicy: .bufferingOldest(1))
        replySlots[msgNum] = continuation
        defer {
            replySlots.removeValue(forKey: msgNum)
            continuation.finish()
        }

        log.debug("TX msgNum=\(msgNum) stage=\(stage, privacy: .public) bytes=\(bytes.count) fragments=\(fragments.count)")
        for fragment in fragments {
            do {
                try await dataConnection.send(.data(fragment))
            } catch {
                throw BaichuanError.connectionFailed("BcUdp send failed: \(error)")
            }
        }

        // Race the reply against the timeout.
        let result = await withTaskGroup(of: BcMessage?.self) { group in
            group.addTask {
                for await msg in stream { return msg }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let msg = result else {
            throw BaichuanError.timedOut(stage: stage)
        }
        return msg
    }

    public func subscribe() async -> AsyncStream<BcMessage> {
        let (stream, continuation) = AsyncStream<BcMessage>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        unsolicitedContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    private func removeSubscriber(id: UUID) {
        unsolicitedContinuations.removeValue(forKey: id)
    }

    public func nextMessageNumber() -> UInt16 {
        let n = nextMsgNum
        nextMsgNum &+= 1
        return n
    }

    public func currentCipher() -> BcCipher { cipher }
    public func setCipher(_ new: BcCipher) { self.cipher = new }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        guard let dataConnection else { return }
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop(on: dataConnection)
        }
    }

    private func runReceiveLoop(on channel: any BcUdpDataConnection) async {
        let stream = await channel.subscribe()
        for await packet in stream {
            if Task.isCancelled { break }
            handlePacket(packet)
        }
    }

    private func handlePacket(_ packet: BcUdpPacket) {
        switch packet {
        case .data(let dataPacket):
            handleDataPacket(dataPacket)
        case .ack:
            // Phase 3d.2-G will wire retransmit / selective-ack
            // logic. The wire shows ~1 Ack per ~10 Data; we
            // ignore them for now since the data-plane bytes
            // are the only thing the upper layer cares about.
            break
        case .disc:
            // Disc packets in the data-plane channel can occur
            // for keepalives or path-renegotiation. Ignored for
            // now; Phase 3d.2-D's concrete connection emits
            // keepalive Discs itself rather than routing them
            // up to us.
            break
        }
    }

    private func handleDataPacket(_ packet: BcUdpDataPacket) {
        guard var reassembler = self.reassembler else { return }
        let outcome = reassembler.ingest(packet)
        readBuffer.append(reassembler.pullAssembled())
        self.reassembler = reassembler

        if case .wrongConnection = outcome {
            // Different session multiplexed on the same UDP
            // socket — not our concern right now (Phase 3d.2
            // assumes a single session).
            return
        }

        // Peel off as many complete BcMessages as the
        // accumulated bytes contain.
        while !readBuffer.isEmpty {
            guard let (msg, consumed) = BcMessage.decode(from: readBuffer, cipher: cipher) else {
                break
            }
            readBuffer.removeFirst(consumed)
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: BcMessage) {
        if let slot = replySlots[msg.header.msgNum] {
            slot.yield(msg)
            return
        }
        for (_, sub) in unsolicitedContinuations {
            sub.yield(msg)
        }
    }

    // MARK: - Inspection (for diagnostics / tests)

    /// The path the hole-punch landed on, once `connect()`
    /// has succeeded. `nil` before the punch completes or
    /// after `close()`.
    public var connectionPath: HolePunchResult.Path? {
        winner?.path
    }
}

// MARK: - Production factory

extension RemoteTransport {

    /// Build a `RemoteTransport` wired to the production
    /// NWConnection-backed stack: discovery via the public
    /// `p2p*.reolink.com` cluster, hole-punch via a real UDP
    /// socket, and a data channel that reuses that same socket
    /// to preserve the NAT mapping. Tests inject the lower
    /// layers directly through the designated init.
    ///
    /// **Status:** the engine sends an empty Disc probe today
    /// (Phase 3d.2-D structural shell). The first real-device
    /// run will tell us whether that elicits a reply or whether
    /// the camera needs a specific probe payload; if the
    /// latter, the fix is a single-field change in
    /// `NWConnectionBcUdpPunchEngine.init`.
    public static func production(
        credentials: BaichuanCredentials,
        uid: String,
        bcUdpTransport: any BcUdpTransport = NWConnectionBcUdpTransport()
    ) -> RemoteTransport {
        let engine = NWConnectionBcUdpPunchEngine()
        return RemoteTransport(
            credentials: credentials,
            uid: uid,
            discovery: P2PDiscovery(transport: bcUdpTransport),
            rendezvous: RendezvousClient(transport: bcUdpTransport),
            probeRunner: engine,
            dataConnectionFactory: { endpoint in
                guard let conn = await engine.dataConnection(for: endpoint) else {
                    throw RemoteTransportError.notYetImplemented(
                        detail: "punch engine had no cached connection for \(endpoint.host):\(endpoint.port)"
                    )
                }
                return conn
            }
        )
    }
}

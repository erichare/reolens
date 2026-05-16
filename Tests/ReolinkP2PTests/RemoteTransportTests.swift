import Testing
import Foundation
import ReolinkBaichuan
import ReolinkBcUdp
@testable import ReolinkP2P

/// Offline tests for `RemoteTransport`. Exercise the full
/// three-step handshake — discovery → rendezvous → punch —
/// against a single `ScriptedBcUdpTransport` stub that routes
/// based on the inbound packet's payload (`<C2M_Q>` →
/// discovery reply; `<C2R_C>` → rendezvous reply).
///
/// What these tests verify:
/// - Three-step happy path: discovery returns rendezvous +
///   relay, rendezvous returns dmap + sid, scheduler probes
///   dmap, factory is invoked with the winner.
/// - Discovery / rendezvous error surfaces (empty discovery,
///   rejected rendezvous).
/// - Hole-punch exhaustion bubbles up as
///   `RemoteTransportError.holePunchExhausted`.
/// - `sendAndAwait` round-trips a real `BcMessage` through
///   the fragmenter + receive loop + reassembler.
/// - `subscribe()` reaches server-initiated pushes.
/// - `close()` is idempotent and tears down state.
@Suite("RemoteTransport — full 3-step handshake")
struct RemoteTransportTests {

    @Test("Empty discovery surfaces noCandidates")
    func emptyDiscovery() async throws {
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .emptyDiscovery),
            probeRunner: AlwaysSucceedRunner(),
            connection: StubDataConnection()
        )
        await #expect(throws: P2PDiscoveryError.self) {
            try await transport.connect()
        }
    }

    @Test("Direct (dmap) succeeds → path is .direct, factory called with dmap")
    func directPunchWins() async throws {
        let connection = StubDataConnection()
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: ScriptedProbeRunner(script: [
                "50.46.39.43:52858": .success,
                "172.232.163.180:51188": .timeout
            ]),
            connection: connection,
            dataConnectionFactory: { endpoint in
                #expect(endpoint.host == "50.46.39.43")
                #expect(endpoint.port == 52858)
                return connection
            }
        )

        try await transport.connect()
        #expect(await connection.connectCallCount == 1)
        #expect(await transport.connectionPath == .direct)
    }

    @Test("Direct fails → falls back to relay; path is .relayed")
    func relayFallback() async throws {
        let connection = StubDataConnection()
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: ScriptedProbeRunner(script: [
                "50.46.39.43:52858": .timeout,
                "172.232.163.180:51188": .success
            ]),
            connection: connection
        )

        try await transport.connect()
        #expect(await transport.connectionPath == .relayed)
    }

    @Test("Both probes fail → throws holePunchExhausted")
    func holePunchExhausted() async throws {
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: ScriptedProbeRunner(script: [:]),   // every probe times out
            connection: StubDataConnection()
        )
        await #expect(throws: RemoteTransportError.self) {
            try await transport.connect()
        }
    }

    @Test("Rendezvous rejection (rsp<0) surfaces as noCandidates")
    func rendezvousRejected() async throws {
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .rendezvousRejected),
            probeRunner: AlwaysSucceedRunner(),
            connection: StubDataConnection()
        )
        await #expect(throws: RemoteTransportError.self) {
            try await transport.connect()
        }
    }

    @Test("connect is idempotent after a successful punch")
    func connectIdempotent() async throws {
        let connection = StubDataConnection()
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: AlwaysSucceedRunner(),
            connection: connection
        )

        try await transport.connect()
        try await transport.connect()
        #expect(await connection.connectCallCount == 1)
    }

    @Test("close is idempotent and tears down the channel")
    func closeIdempotent() async throws {
        let connection = StubDataConnection()
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: AlwaysSucceedRunner(),
            connection: connection
        )

        try await transport.connect()
        await transport.close()
        await transport.close()
        #expect(await connection.closeCallCount == 1)
        #expect(await transport.connectionPath == nil)
    }

    @Test("sendAndAwait without connect throws notYetImplemented")
    func sendBeforeConnectThrows() async throws {
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .emptyDiscovery),
            probeRunner: AlwaysSucceedRunner(),
            connection: StubDataConnection()
        )
        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.sendAndAwait(
                BcMessage(header: makeHeader(msgNum: 0)),
                timeout: 1,
                stage: "test"
            )
        }
    }

    @Test("sendAndAwait fragments outbound bytes and routes the matching reply")
    func sendAndAwaitFullLoop() async throws {
        let connection = StubDataConnection()
        let pinnedConnectionID: UInt32 = 0x0000_02B5
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: AlwaysSucceedRunner(),
            connection: connection,
            connectionID: pinnedConnectionID
        )
        try await transport.connect()

        let request = BcMessage(header: makeHeader(msgNum: 42))

        let replyMessage = BcMessage(header: makeHeader(msgNum: 42, responseCode: 200))
        let replyBytes = replyMessage.encode(cipher: .unencrypted)
        let inboundPacket = BcUdpDataPacket(
            connectionID: pinnedConnectionID,
            sequence: 0,
            payload: replyBytes
        )

        async let result = transport.sendAndAwait(request, timeout: 2, stage: "test")

        try await Task.sleep(for: .milliseconds(30))
        await connection.deliver(.data(inboundPacket))

        let reply = try await result
        #expect(reply.header.msgNum == 42)
        #expect(reply.header.responseCode == 200)

        let sent = await connection.sentPackets
        #expect(sent.count >= 1)
    }

    @Test("Unsolicited inbound BcMessage reaches subscribe() consumers")
    func receiveLoopDispatchesToSubscribers() async throws {
        let connection = StubDataConnection()
        let pinnedConnectionID: UInt32 = 0xDEAD_BEEF
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: AlwaysSucceedRunner(),
            connection: connection,
            connectionID: pinnedConnectionID
        )
        try await transport.connect()

        let stream = await transport.subscribe()

        let header = makeHeader(msgID: 33, msgNum: 0xBEEF)
        let msg = BcMessage(header: header)
        let bytes = msg.encode(cipher: .unencrypted)
        let inbound = BcUdpDataPacket(
            connectionID: pinnedConnectionID,
            sequence: 0,
            payload: bytes
        )
        await connection.deliver(.data(inbound))

        let received = await withTaskGroup(of: BcMessage?.self) { group in
            group.addTask {
                for await m in stream { return m }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        let m = try #require(received)
        #expect(m.header.msgID == 33)
        #expect(m.header.msgNum == 0xBEEF)
    }

    @Test("sendAndAwait honours its timeout when no reply lands")
    func sendAndAwaitTimesOut() async throws {
        let connection = StubDataConnection()
        let transport = makeTransport(
            bcUdpTransport: ScriptedBcUdpTransport(scenario: .fullHandshake),
            probeRunner: AlwaysSucceedRunner(),
            connection: connection
        )
        try await transport.connect()

        await #expect(throws: BaichuanError.self) {
            _ = try await transport.sendAndAwait(
                BcMessage(header: makeHeader(msgNum: 99)),
                timeout: 0.3,
                stage: "test-timeout"
            )
        }
    }

    // MARK: - Helpers

    private func makeTransport(
        bcUdpTransport: any BcUdpTransport,
        probeRunner: any HolePunchProbeRunner,
        connection: StubDataConnection,
        dataConnectionFactory: (@Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection)? = nil,
        connectionID: UInt32? = nil
    ) -> RemoteTransport {
        let factory: @Sendable (DiscoveryXML.Endpoint) async throws -> any BcUdpDataConnection
        if let dataConnectionFactory {
            factory = dataConnectionFactory
        } else {
            factory = { _ in connection }
        }
        return RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: P2PDiscovery(transport: bcUdpTransport),
            rendezvous: RendezvousClient(transport: bcUdpTransport),
            probeRunner: probeRunner,
            dataConnectionFactory: factory,
            connectionID: connectionID
        )
    }

    private func makeCreds() -> BaichuanCredentials {
        BaichuanCredentials(
            host: "remote",
            port: 9000,
            username: "user",
            password: "pass"
        )
    }

    private func makeHeader(
        msgID: UInt32 = 80,
        msgNum: UInt16,
        responseCode: UInt16 = 0
    ) -> BcHeader {
        BcHeader(
            msgID: msgID,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: msgNum,
            responseCode: responseCode,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
    }
}

// MARK: - Stubs

/// Scripts the full handshake via a single transport stub.
/// Routes inbound packets based on the decrypted XML payload —
/// `<C2M_Q>` gets a discovery reply (rendezvous + relay);
/// `<C2R_C>` gets a rendezvous reply (dmap + relay + sid).
///
/// The rendezvous + dmap values are taken from the 2026-05-16
/// probe pcap so tests anchor to real wire data.
private struct ScriptedBcUdpTransport: BcUdpTransport {
    enum Scenario: Sendable {
        case emptyDiscovery
        case fullHandshake
        case rendezvousRejected
    }

    let scenario: Scenario
    private static let replySenderID: UInt32 = 0xCAFE_BABE

    func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        guard case .disc(let disc) = packet else {
            throw BcUdpTransportError.malformedReply(host: host, port: port)
        }
        let plain = DiscoveryXMLCrypto.decrypt(disc.payload, offset: disc.senderID)
        let xml = String(data: plain, encoding: .utf8) ?? ""

        let replyPayload: Data
        if xml.contains("<C2M_Q>") {
            replyPayload = discoveryReplyXML()
        } else if xml.contains("<C2R_C>") {
            replyPayload = rendezvousReplyXML()
        } else {
            throw BcUdpTransportError.malformedReply(host: host, port: port)
        }

        let cipher = DiscoveryXMLCrypto.encrypt(replyPayload, offset: Self.replySenderID)
        return .disc(BcUdpDiscPacket(senderID: Self.replySenderID, payload: cipher))
    }

    private func discoveryReplyXML() -> Data {
        switch scenario {
        case .emptyDiscovery:
            return DiscoveryXML.LookupResponse(responseCode: -3).encode()
        case .fullHandshake, .rendezvousRejected:
            return DiscoveryXML.LookupResponse(
                rendezvous: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58200),
                relay: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58100),
                responseCode: 0
            ).encode()
        }
    }

    private func rendezvousReplyXML() -> Data {
        switch scenario {
        case .rendezvousRejected:
            return DiscoveryXML.RendezvousReply(responseCode: -3).encode()
        case .fullHandshake, .emptyDiscovery:
            return DiscoveryXML.RendezvousReply(
                deviceLanEndpoint: DiscoveryXML.Endpoint(host: "192.168.113.228", port: 52858),
                deviceMappedEndpoint: DiscoveryXML.Endpoint(host: "50.46.39.43", port: 52858),
                relay: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 51188),
                sessionID: 7_332_712,
                responseCode: 0
            ).encode()
        }
    }
}

private struct AlwaysSucceedRunner: HolePunchProbeRunner {
    func probe(_ endpoint: DiscoveryXML.Endpoint, deadline: Duration) async throws -> ProbeOutcome {
        .success
    }
}

private struct ScriptedProbeRunner: HolePunchProbeRunner {
    enum Scripted: Sendable { case success; case timeout }
    let script: [String: Scripted]
    func probe(_ endpoint: DiscoveryXML.Endpoint, deadline: Duration) async throws -> ProbeOutcome {
        switch script["\(endpoint.host):\(endpoint.port)"] {
        case .success?: return .success
        case .timeout?: return .timeout
        case nil:       return .timeout
        }
    }
}

private actor StubDataConnection: BcUdpDataConnection {
    private(set) var connectCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var sentPackets: [BcUdpPacket] = []

    private var inboundContinuation: AsyncStream<BcUdpPacket>.Continuation?
    private var inboundStream: AsyncStream<BcUdpPacket>?
    private var pendingBeforeSubscribe: [BcUdpPacket] = []

    func connect() async throws {
        connectCallCount += 1
    }

    func send(_ packet: BcUdpPacket) async throws {
        sendCallCount += 1
        sentPackets.append(packet)
    }

    func subscribe() async -> AsyncStream<BcUdpPacket> {
        if let stream = inboundStream { return stream }
        let (stream, cont) = AsyncStream<BcUdpPacket>.makeStream()
        inboundStream = stream
        inboundContinuation = cont
        for packet in pendingBeforeSubscribe {
            cont.yield(packet)
        }
        pendingBeforeSubscribe.removeAll()
        return stream
    }

    func deliver(_ packet: BcUdpPacket) {
        if let cont = inboundContinuation {
            cont.yield(packet)
        } else {
            pendingBeforeSubscribe.append(packet)
        }
    }

    func close() async {
        closeCallCount += 1
        inboundContinuation?.finish()
    }
}

import Testing
import Foundation
import ReolinkBaichuan
import ReolinkBcUdp
@testable import ReolinkP2P

/// Offline tests for `RemoteTransport` (Phase 3d.2 partial).
/// Exercises the discovery → hole-punch → data-channel handoff
/// via scripted stubs. The actual UDP wire (
/// `NWConnectionBcUdpDataConnection`) and the inbound
/// receive-loop wiring still land later.
///
/// What these tests verify:
/// - Empty discovery surfaces the upstream
///   `P2PDiscoveryError.exhausted`.
/// - A non-empty discovery result drives the hole-punch
///   scheduler, which feeds the winning endpoint to the
///   data-connection factory.
/// - The `connectionPath` reflects whether the winner was
///   direct or relayed.
/// - `close()` is idempotent and tears down the data channel.
/// - `sendAndAwait` still throws `notYetImplemented` while
///   the receive loop is pending.
@Suite("RemoteTransport — connect via hole-punch")
struct RemoteTransportTests {

    @Test("Empty discovery surfaces P2PDiscoveryError.exhausted")
    func emptyDiscovery() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .empty)
        let discovery = P2PDiscovery(transport: bcUdp)
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in
                Issue.record("Factory should not run on empty discovery")
                throw RemoteTransportError.notYetImplemented(detail: "unreachable")
            }
        )
        await #expect(throws: P2PDiscoveryError.self) {
            try await transport.connect()
        }
    }

    @Test("Direct candidate wins → factory called with that endpoint, path is .direct")
    func directWinsAndFactoryCalled() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: ScriptedProbeRunner(script: [
                "203.0.113.10:9000": .success,
                "relay.example:8443": .timeout
            ]),
            dataConnectionFactory: { endpoint in
                #expect(endpoint.host == "203.0.113.10")
                #expect(endpoint.port == 9000)
                return connection
            }
        )

        try await transport.connect()
        #expect(await connection.connectCallCount == 1)
        #expect(await transport.connectionPath == .direct)
    }

    @Test("Direct fails → falls back to relay; path is .relayed")
    func relayFallbackPath() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: ScriptedProbeRunner(script: [
                "203.0.113.10:9000": .timeout,
                "relay.example:8443": .success
            ]),
            dataConnectionFactory: { endpoint in
                #expect(endpoint.host == "relay.example")
                return connection
            }
        )

        try await transport.connect()
        #expect(await transport.connectionPath == .relayed)
    }

    @Test("Both probes fail → throws holePunchExhausted")
    func holePunchExhausted() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: ScriptedProbeRunner(script: [
                "203.0.113.10:9000": .timeout,
                "relay.example:8443": .timeout
            ]),
            dataConnectionFactory: { _ in
                Issue.record("Factory should not run when hole-punch fails")
                throw RemoteTransportError.notYetImplemented(detail: "unreachable")
            }
        )

        await #expect(throws: RemoteTransportError.self) {
            try await transport.connect()
        }
    }

    @Test("connect is idempotent after a successful punch")
    func connectIdempotent() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection }
        )

        try await transport.connect()
        try await transport.connect()
        #expect(await connection.connectCallCount == 1)
    }

    @Test("close is idempotent and tears down the channel")
    func closeIdempotent() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection }
        )

        try await transport.connect()
        await transport.close()
        await transport.close()
        #expect(await connection.closeCallCount == 1)
        #expect(await transport.connectionPath == nil)
    }

    @Test("sendAndAwait without connect throws notYetImplemented")
    func sendBeforeConnectThrows() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .empty)
        let discovery = P2PDiscovery(transport: bcUdp)
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in StubDataConnection() }
        )

        let header = makeHeader(msgNum: 0)
        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.sendAndAwait(
                BcMessage(header: header),
                timeout: 1,
                stage: "test"
            )
        }
    }

    @Test("sendAndAwait fragments outbound bytes and routes the matching reply")
    func sendAndAwaitFullLoop() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let pinnedConnectionID: UInt32 = 0x0000_02B5
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection },
            connectionID: pinnedConnectionID
        )
        try await transport.connect()

        let request = BcMessage(header: makeHeader(msgNum: 42))

        // Construct the reply we want the camera to "send".
        let replyHeader = makeHeader(msgNum: 42, responseCode: 200)
        let replyMessage = BcMessage(header: replyHeader)
        let replyBytes = replyMessage.encode(cipher: .unencrypted)
        let inboundPacket = BcUdpDataPacket(
            connectionID: pinnedConnectionID,
            sequence: 0,
            payload: replyBytes
        )

        // Race the sendAndAwait against an in-flight delivery.
        // The reply slot is registered BEFORE the send returns
        // so even an immediate delivery doesn't slip past.
        async let result = transport.sendAndAwait(
            request,
            timeout: 2,
            stage: "test"
        )

        // Yield once so the actor processes the send, then push
        // the reply into the receive loop.
        try await Task.sleep(for: .milliseconds(30))
        await connection.deliver(.data(inboundPacket))

        let reply = try await result
        #expect(reply.header.msgNum == 42)
        #expect(reply.header.responseCode == 200)
        #expect(reply.header.msgID == 80)

        // Verify the request was actually fragmented + sent.
        let sent = await connection.sentPackets
        #expect(sent.count >= 1)
        if case .data(let firstFragment) = sent.first {
            #expect(firstFragment.connectionID == pinnedConnectionID)
            #expect(firstFragment.sequence == 0)
        } else {
            Issue.record("Expected a Data packet to be sent")
        }
    }

    @Test("Unsolicited inbound BcMessage reaches subscribe() consumers")
    func receiveLoopDispatchesToSubscribers() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let pinnedConnectionID: UInt32 = 0xDEAD_BEEF
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection },
            connectionID: pinnedConnectionID
        )
        try await transport.connect()

        let stream = await transport.subscribe()

        // Push a server-initiated message (msg_num=0xBEEF, no
        // matching reply slot).
        let header = makeHeader(msgID: 33, msgNum: 0xBEEF)
        let msg = BcMessage(header: header)
        let bytes = msg.encode(cipher: .unencrypted)
        let inbound = BcUdpDataPacket(
            connectionID: pinnedConnectionID,
            sequence: 0,
            payload: bytes
        )
        await connection.deliver(.data(inbound))

        // Race the first stream element against a wall-clock
        // timeout — same pattern as LANTransport's tests.
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

    @Test("Multi-fragment reply reassembles before dispatch")
    func multiFragmentReply() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let pinnedConnectionID: UInt32 = 0xFEED_FACE
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection },
            connectionID: pinnedConnectionID
        )
        try await transport.connect()

        // Construct a Baichuan reply with a non-empty body so
        // we can chop it across multiple BcUdp Data fragments.
        let body = Data(repeating: 0x55, count: 200)
        let replyHeader = BcHeader(
            msgID: 80,
            bodyLength: UInt32(body.count),
            channelID: 0,
            streamType: 0,
            msgNum: 7,
            responseCode: 200,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let replyMessage = BcMessage(header: replyHeader, body: body)
        let replyBytes = replyMessage.encode(cipher: .unencrypted)
        // Chop into 50-byte fragments.
        let chunkSize = 50
        var fragments: [BcUdpDataPacket] = []
        var offset = 0
        var seq: UInt32 = 0
        while offset < replyBytes.count {
            let end = min(offset + chunkSize, replyBytes.count)
            fragments.append(
                BcUdpDataPacket(
                    connectionID: pinnedConnectionID,
                    sequence: seq,
                    payload: replyBytes.subdata(in: offset..<end)
                )
            )
            seq &+= 1
            offset = end
        }

        async let result = transport.sendAndAwait(
            BcMessage(header: makeHeader(msgNum: 7)),
            timeout: 2,
            stage: "test"
        )

        try await Task.sleep(for: .milliseconds(20))
        for fragment in fragments {
            await connection.deliver(.data(fragment))
        }

        let reply = try await result
        #expect(reply.header.msgNum == 7)
        #expect(reply.header.responseCode == 200)
        #expect(reply.body.count == 200)
        #expect(reply.body == body)
    }

    @Test("sendAndAwait honours its timeout when no reply lands")
    func sendAndAwaitTimesOut() async throws {
        let bcUdp = ScriptedBcUdpTransport(
            reply: .withCandidates(registration: ("203.0.113.10", 9000), relay: ("relay.example", 8443))
        )
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            probeRunner: AlwaysSucceedRunner(),
            dataConnectionFactory: { _ in connection }
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

    // MARK: - Helpers

    private func makeCreds() -> BaichuanCredentials {
        BaichuanCredentials(
            host: "remote",
            port: 9000,
            username: "user",
            password: "pass"
        )
    }
}

// MARK: - Stubs

/// Stub `BcUdpTransport` that always replies with the same
/// canned packet. Encrypts replies with a fixed reply
/// `senderID` so the decryption layer in `P2PDiscovery` is
/// exercised end-to-end against the wire-truth cipher.
private struct ScriptedBcUdpTransport: BcUdpTransport {
    enum CannedReply: Sendable {
        case empty
        case withCandidates(
            registration: (host: String, port: UInt16),
            relay: (host: String, port: UInt16)
        )
    }

    let reply: CannedReply
    private static let replySenderID: UInt32 = 0xCAFE_BABE

    func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        let plain: Data
        switch reply {
        case .empty:
            plain = DiscoveryXML.LookupResponse(responseCode: -3).encode()
        case .withCandidates(let reg, let rel):
            plain = DiscoveryXML.LookupResponse(
                registration: DiscoveryXML.Endpoint(host: reg.host, port: reg.port),
                relay: DiscoveryXML.Endpoint(host: rel.host, port: rel.port),
                responseCode: 0
            ).encode()
        }
        let cipher = DiscoveryXMLCrypto.encrypt(plain, offset: Self.replySenderID)
        return .disc(BcUdpDiscPacket(senderID: Self.replySenderID, payload: cipher))
    }
}

/// Probe runner that always returns `.success` for the first
/// endpoint it sees. Used by tests that don't care which
/// candidate wins, only that *some* candidate wins.
private struct AlwaysSucceedRunner: HolePunchProbeRunner {
    func probe(_ endpoint: DiscoveryXML.Endpoint, deadline: Duration) async throws -> ProbeOutcome {
        .success
    }
}

/// Probe runner that consults a dictionary keyed on
/// `"host:port"` and returns the scripted outcome.
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

/// Test-side data-connection stub. Records outbound packets,
/// counts connect/close calls, and exposes a `deliver(...)`
/// helper that pushes inbound packets to the transport's
/// receive loop.
private actor StubDataConnection: BcUdpDataConnection {
    private(set) var connectCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var sentPackets: [BcUdpPacket] = []

    private var inboundContinuation: AsyncStream<BcUdpPacket>.Continuation?
    private var inboundStream: AsyncStream<BcUdpPacket>?
    /// Buffer of packets delivered before any subscriber
    /// registered. Avoids a race in tests where `connect()`
    /// returns before the receive task has actually subscribed
    /// — the buffered packets are flushed as soon as the first
    /// `subscribe()` call arrives.
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

    /// Push a packet into the transport's receive loop. If
    /// no subscriber is registered yet (the receive task is
    /// still spinning up), buffer until one is.
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

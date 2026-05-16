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

    @Test("sendAndAwait still throws notYetImplemented pending Phase 3d.2-F")
    func sendNotYetImplemented() async throws {
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
        let header = BcHeader(
            msgID: 80,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: 0,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.sendAndAwait(
                BcMessage(header: header),
                timeout: 1,
                stage: "test"
            )
        }
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

/// Records connect/send/close call counts so tests can assert
/// the state-machine actually drove the data channel.
private actor StubDataConnection: BcUdpDataConnection {
    private(set) var connectCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var closeCallCount = 0

    func connect() async throws {
        connectCallCount += 1
    }

    func send(_ packet: BcUdpPacket) async throws {
        sendCallCount += 1
    }

    func subscribe() async -> AsyncStream<BcUdpPacket> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func close() async {
        closeCallCount += 1
    }
}

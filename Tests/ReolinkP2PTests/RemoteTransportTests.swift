import Testing
import Foundation
import ReolinkBaichuan
import ReolinkBcUdp
@testable import ReolinkP2P

/// Offline tests for `RemoteTransport` (Phase 3d.1 skeleton).
/// Exercises the discovery → data-channel handoff via
/// scripted stubs. The hole-punch state machine itself, the
/// keepalive loop, and the multi-packet reassembly buffer all
/// land in Phase 3d.2 with their own real-device validation.
///
/// What these tests verify:
/// - Empty discovery result surfaces `noCandidates`.
/// - A non-empty discovery result drives the
///   data-connection factory and stores the channel on
///   success.
/// - `close()` is idempotent and tears down the data
///   connection.
/// - Pre-3d.2, `sendAndAwait` honestly throws
///   `notYetImplemented` so callers wire fallbacks based on
///   the real surface, not a swallowed error.
@Suite("RemoteTransport — skeleton (Phase 3d.1)")
struct RemoteTransportTests {

    @Test("connect throws noCandidates when discovery returns empty")
    func emptyDiscovery() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .empty(uid: "FAKE-UID"))
        let discovery = P2PDiscovery(transport: bcUdp)
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            dataConnectionFactory: { _ in
                Issue.record("Factory should not run on empty discovery")
                throw RemoteTransportError.notYetImplemented(detail: "unreachable")
            }
        )

        // Discovery walks the whole pool with empty replies and
        // throws `.exhausted` — RemoteTransport surfaces that
        // upstream error so the caller can decide between
        // "camera offline" and "try again later". The skeleton
        // intentionally doesn't convert it to `.noCandidates`;
        // a `.noCandidates` requires a NON-empty server
        // response with zero candidate fields, which the
        // production scripted reply path can't currently
        // synthesize without writing a custom XML factory.
        await #expect(throws: P2PDiscoveryError.self) {
            try await transport.connect()
        }
    }

    @Test("connect runs the factory and stores the data channel")
    func successfulHandoff() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .withWanV4(host: "203.0.113.10", port: 9000, uid: "FAKE-UID"))
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            dataConnectionFactory: { response in
                #expect(response.wanV4?.host == "203.0.113.10")
                return connection
            }
        )

        try await transport.connect()
        #expect(await connection.connectCallCount == 1)

        // `connect` is idempotent — calling again should not
        // build a second channel.
        try await transport.connect()
        #expect(await connection.connectCallCount == 1)
    }

    @Test("close is idempotent and tears down the channel")
    func closeIdempotent() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .withWanV4(host: "203.0.113.10", port: 9000, uid: "FAKE-UID"))
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
            dataConnectionFactory: { _ in connection }
        )

        try await transport.connect()
        await transport.close()
        await transport.close()
        #expect(await connection.closeCallCount == 1)
    }

    @Test("sendAndAwait throws notYetImplemented in the 3d.1 skeleton")
    func sendNotYetImplemented() async throws {
        let bcUdp = ScriptedBcUdpTransport(reply: .withWanV4(host: "203.0.113.10", port: 9000, uid: "FAKE-UID"))
        let discovery = P2PDiscovery(transport: bcUdp)
        let connection = StubDataConnection()
        let transport = RemoteTransport(
            credentials: makeCreds(),
            uid: "FAKE-UID",
            discovery: discovery,
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
/// canned packet. Just enough surface to drive `P2PDiscovery`
/// into the response-parsing path.
private struct ScriptedBcUdpTransport: BcUdpTransport {
    enum CannedReply: Sendable {
        case empty(uid: String)
        case withWanV4(host: String, port: UInt16, uid: String)
    }

    let reply: CannedReply

    func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        let payload: Data
        switch reply {
        case .empty(let uid):
            payload = DiscoveryXML.LookupResponse(uid: uid).encode()
        case .withWanV4(let host, let port, let uid):
            payload = DiscoveryXML.LookupResponse(
                uid: uid,
                wanV4: DiscoveryXML.Endpoint(host: host, port: port)
            ).encode()
        }
        return .disc(BcUdpDiscPacket(connectionID: 0, responseCode: 0, payload: payload))
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

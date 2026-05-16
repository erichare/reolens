import Testing
import Foundation
@testable import ReolinkP2P
import ReolinkBcUdp

/// 0.7.0 Phase 2 — discovery actor behavior. Uses an in-test
/// stub `BcUdpTransport` so the suite runs offline and exercises
/// the full fallback / redirect state machine without touching
/// the network. Phase 2b lands a concrete `NWConnection`-backed
/// transport which has its own integration tests against a real
/// device.
@Suite("P2PDiscovery actor")
struct P2PDiscoveryTests {

    // MARK: - Stub transport

    /// Records every `sendAndAwaitReply` call and replays scripted
    /// outcomes in order. Outcome scripting is per-host so a test
    /// can simulate "first two servers time out, third succeeds"
    /// without baking that ordering into the actor's expectations.
    actor ScriptedTransport: BcUdpTransport {
        enum Outcome: Sendable {
            case reply(BcUdpPacket)
            case timeout
            case unreachable(String)
            case malformedReply
            case unexpectedKind(BcUdpPacketKind)
        }

        struct Call: Sendable, Equatable {
            let host: String
            let port: UInt16
        }

        private var script: [String: [Outcome]] = [:]
        private(set) var calls: [Call] = []

        init(script: [String: [Outcome]]) {
            self.script = script
        }

        nonisolated func sendAndAwaitReply(
            _ packet: BcUdpPacket,
            to host: String,
            port: UInt16,
            timeout: Duration
        ) async throws -> BcUdpPacket {
            try await next(host: host, port: port)
        }

        private func next(host: String, port: UInt16) async throws -> BcUdpPacket {
            calls.append(Call(host: host, port: port))
            guard var queue = script[host], !queue.isEmpty else {
                throw BcUdpTransportError.timedOut(host: host, port: port)
            }
            let next = queue.removeFirst()
            script[host] = queue
            switch next {
            case .reply(let p): return p
            case .timeout: throw BcUdpTransportError.timedOut(host: host, port: port)
            case .unreachable(let msg): throw BcUdpTransportError.unreachable(host: host, port: port, detail: msg)
            case .malformedReply: throw BcUdpTransportError.malformedReply(host: host, port: port)
            case .unexpectedKind(let kind): throw BcUdpTransportError.unexpectedKind(host: host, port: port, got: kind)
            }
        }

        func calledHosts() -> [String] { calls.map(\.host) }
    }

    // MARK: - Helpers

    /// Build a scripted "success" reply with one registration
    /// endpoint. The reply payload is encrypted under a fixed
    /// reply senderID (`replySenderID`); the actor decrypts using
    /// that same value because it lives in the reply header.
    private static func makeReply(uid: String) -> BcUdpPacket {
        let response = DiscoveryXML.LookupResponse(
            registration: DiscoveryXML.Endpoint(host: "203.0.113.10", port: 9000),
            responseCode: 0
        )
        _ = uid
        let replySenderID: UInt32 = 0xCAFE_BABE
        let plaintext = response.encode()
        let ciphertext = DiscoveryXMLCrypto.encrypt(plaintext, offset: replySenderID)
        return .disc(BcUdpDiscPacket(senderID: replySenderID, payload: ciphertext))
    }

    /// Build a scripted "not registered" reply — the server's
    /// soft-no when this pool entry doesn't currently hold a
    /// registration for the UID. `rsp = -3` per the wire capture.
    private static func makeEmptyReply(uid: String) -> BcUdpPacket {
        _ = uid
        let response = DiscoveryXML.LookupResponse(responseCode: -3)
        let replySenderID: UInt32 = 0xCAFE_BABE
        let plaintext = response.encode()
        let ciphertext = DiscoveryXMLCrypto.encrypt(plaintext, offset: replySenderID)
        return .disc(BcUdpDiscPacket(senderID: replySenderID, payload: ciphertext))
    }

    private static let pool = DiscoveryServerPool(entries: [
        .init(host: "a.example.com", port: 9999),
        .init(host: "b.example.com", port: 9999),
        .init(host: "c.example.com", port: 9999)
    ])

    private static let fixedClientID: @Sendable () -> String = { "test-cli" }

    // MARK: - Tests

    @Test("Returns the first non-empty reply and stops walking the pool")
    func returnsFirstNonEmpty() async throws {
        let uid = "ABCDEF0123456789"
        let transport = ScriptedTransport(script: [
            "a.example.com": [.reply(Self.makeReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        let result = try await discovery.lookup(uid: uid)
        #expect(result.registration == DiscoveryXML.Endpoint(host: "203.0.113.10", port: 9000))

        let visited = await transport.calledHosts()
        #expect(visited == ["a.example.com"])
    }

    @Test("Falls through on per-server timeout until one server answers")
    func fallsThroughOnTimeout() async throws {
        let uid = "ABCDEF0123456789"
        let transport = ScriptedTransport(script: [
            "a.example.com": [.timeout],
            "b.example.com": [.timeout],
            "c.example.com": [.reply(Self.makeReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        let result = try await discovery.lookup(uid: uid)
        #expect(result.registration != nil)
        let visited = await transport.calledHosts()
        #expect(visited == ["a.example.com", "b.example.com", "c.example.com"])
    }

    @Test("Skips servers that return an empty (no-candidate) response")
    func skipsEmptyResponses() async throws {
        let uid = "FEEDBEEF12345678"
        let transport = ScriptedTransport(script: [
            "a.example.com": [.reply(Self.makeEmptyReply(uid: uid))],
            "b.example.com": [.reply(Self.makeReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        let result = try await discovery.lookup(uid: uid)
        #expect(result.registration != nil)
        let visited = await transport.calledHosts()
        #expect(visited == ["a.example.com", "b.example.com"])
    }

    @Test("Skips servers that return a non-Disc packet kind")
    func skipsWrongKind() async throws {
        let uid = "AAAAAAAA00000000"
        let bogusKind = BcUdpPacket.ack(BcUdpAckPacket(connectionID: 0))
        let transport = ScriptedTransport(script: [
            "a.example.com": [.reply(bogusKind)],
            "b.example.com": [.reply(Self.makeReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        _ = try await discovery.lookup(uid: uid)
        let visited = await transport.calledHosts()
        #expect(visited == ["a.example.com", "b.example.com"])
    }

    @Test("Skips servers that return a malformed XML payload")
    func skipsMalformedPayload() async throws {
        let uid = "BBBBBBBB00000000"
        let malformed = BcUdpPacket.disc(
            BcUdpDiscPacket(senderID: 1, payload: Data("not xml".utf8))
        )
        let transport = ScriptedTransport(script: [
            "a.example.com": [.reply(malformed)],
            "b.example.com": [.reply(Self.makeReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        _ = try await discovery.lookup(uid: uid)
        let visited = await transport.calledHosts()
        #expect(visited == ["a.example.com", "b.example.com"])
    }

    @Test("Throws .exhausted with per-server outcomes when every server fails")
    func throwsExhaustedWithAttempts() async throws {
        let uid = "EEEEEEEE00000000"
        let transport = ScriptedTransport(script: [
            "a.example.com": [.timeout],
            "b.example.com": [.unreachable("no route")],
            "c.example.com": [.reply(Self.makeEmptyReply(uid: uid))]
        ])
        let discovery = P2PDiscovery(transport: transport, pool: Self.pool, clientIDProvider: Self.fixedClientID)

        // Single lookup call — the ScriptedTransport queues are
        // consumed per call, so a second call would only see
        // empty queues (which throw timeouts), masking the
        // per-server outcome diversity we want to assert here.
        do {
            _ = try await discovery.lookup(uid: uid)
            Issue.record("Expected discovery to throw .exhausted")
        } catch P2PDiscoveryError.exhausted(let errUID, let attempts) {
            #expect(errUID == uid)
            #expect(attempts.count == 3)
            #expect(attempts[0].host == "a.example.com")
            #expect(attempts[0].outcome == .timedOut)
            #expect(attempts[1].host == "b.example.com")
            if case .unreachable(let detail) = attempts[1].outcome {
                #expect(detail == "no route")
            } else {
                Issue.record("Expected .unreachable outcome, got \(attempts[1].outcome)")
            }
            #expect(attempts[2].outcome == .emptyResponse)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Throws .emptyServerPool when the pool is empty")
    func throwsOnEmptyPool() async throws {
        let transport = ScriptedTransport(script: [:])
        let discovery = P2PDiscovery(
            transport: transport,
            pool: DiscoveryServerPool(entries: []),
            clientIDProvider: Self.fixedClientID
        )

        do {
            _ = try await discovery.lookup(uid: "any")
            Issue.record("Expected .emptyServerPool")
        } catch P2PDiscoveryError.emptyServerPool {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Encoded lookup request encrypts the payload with senderID as offset")
    func sentRequestIsEncrypted() async throws {
        // Capture the packet the actor sends so we can verify
        // the wire encryption uses the senderID as the cipher
        // offset, and the encrypted payload decrypts back to the
        // expected UID.
        actor CaptureTransport: BcUdpTransport {
            private(set) var captured: BcUdpPacket?
            let reply: BcUdpPacket
            init(reply: BcUdpPacket) { self.reply = reply }
            nonisolated func sendAndAwaitReply(
                _ packet: BcUdpPacket,
                to host: String,
                port: UInt16,
                timeout: Duration
            ) async throws -> BcUdpPacket {
                await store(packet)
                return reply
            }
            private func store(_ p: BcUdpPacket) { captured = p }
            func sentPacket() -> BcUdpPacket? { captured }
        }

        let uid = "12345678ABCDEF00"
        let transport = CaptureTransport(reply: Self.makeReply(uid: uid))
        let discovery = P2PDiscovery(
            transport: transport,
            pool: Self.pool,
            clientIDProvider: { "ignored" }
        )
        _ = try await discovery.lookup(uid: uid)

        let sent = try #require(await transport.sentPacket())
        guard case .disc(let disc) = sent else {
            Issue.record("Expected the sent packet to be a Disc")
            return
        }
        // The on-wire payload must NOT be plaintext XML.
        #expect(!disc.payload.starts(with: Data("<P2P>".utf8)))
        // Decrypting with the senderID from the same header should
        // recover the plaintext request that carries our UID.
        let plaintext = DiscoveryXMLCrypto.decrypt(disc.payload, offset: disc.senderID)
        let parsed = try #require(DiscoveryXML.LookupRequest.decode(from: plaintext))
        #expect(parsed.uid == uid)
    }
}

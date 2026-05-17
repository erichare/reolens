import Testing
import Foundation
import ReolinkBcUdp
@testable import ReolinkP2P

@Suite("RendezvousClient — C2R_C / R2C exchange")
struct RendezvousClientTests {

    private static let rendezvous = DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58200)
    private static let relay = DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58100)

    @Test("Success reply with dmap returns the parsed RendezvousReply")
    func successfulRendezvous() async throws {
        let stub = ScriptedTransport(reply: .success(
            dmap: ("50.46.39.43", 52858),
            dev: ("192.168.113.228", 52858),
            sid: 7_332_712
        ))
        let client = RendezvousClient(transport: stub)
        let result = try await client.rendezvous(
            uid: "9527000I500W1NSQ",
            rendezvousEndpoint: Self.rendezvous,
            relayHint: Self.relay,
            connectionID: 31000
        )
        #expect(result.deviceMappedEndpoint?.host == "50.46.39.43")
        #expect(result.deviceMappedEndpoint?.port == 52858)
        #expect(result.deviceLanEndpoint?.host == "192.168.113.228")
        #expect(result.sessionID == 7_332_712)
        #expect(result.responseCode == 0)
    }

    @Test("Server rejects with non-zero rsp → serverRejected")
    func serverRejection() async throws {
        let stub = ScriptedTransport(reply: .rejected(code: -3))
        let client = RendezvousClient(transport: stub)
        do {
            _ = try await client.rendezvous(
                uid: "FAKE",
                rendezvousEndpoint: Self.rendezvous,
                relayHint: Self.relay,
                connectionID: 1
            )
            Issue.record("Expected serverRejected to throw")
        } catch RendezvousError.serverRejected(let code) {
            #expect(code == -3)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Success-coded reply with no dmap is treated as malformed")
    func successWithoutDmapIsMalformed() async throws {
        let stub = ScriptedTransport(reply: .successWithoutDmap)
        let client = RendezvousClient(transport: stub)
        do {
            _ = try await client.rendezvous(
                uid: "FAKE",
                rendezvousEndpoint: Self.rendezvous,
                relayHint: Self.relay,
                connectionID: 1
            )
            Issue.record("Expected malformedReply")
        } catch RendezvousError.malformedReply {
            // expected
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Outbound packet carries the encrypted C2R_C XML with our cid")
    func outboundRequestIsEncrypted() async throws {
        let capture = CapturingTransport(reply: .success(
            dmap: ("50.46.39.43", 52858),
            dev: ("192.168.113.228", 52858),
            sid: 7_332_712
        ))
        let client = RendezvousClient(transport: capture)
        _ = try await client.rendezvous(
            uid: "9527000I500W1NSQ",
            rendezvousEndpoint: Self.rendezvous,
            relayHint: Self.relay,
            connectionID: 31000
        )
        let sent = try #require(await capture.lastSent())
        guard case .disc(let disc) = sent else {
            Issue.record("Expected Disc packet")
            return
        }
        // The wire MUST NOT be plaintext XML.
        #expect(!disc.payload.starts(with: Data("<P2P>".utf8)))
        // Decrypt with senderID and check our cid is present.
        let plain = DiscoveryXMLCrypto.decrypt(disc.payload, offset: disc.senderID)
        let xml = try #require(String(data: plain, encoding: .utf8))
        #expect(xml.contains("<C2R_C>"))
        #expect(xml.contains("<uid>9527000I500W1NSQ</uid>"))
        #expect(xml.contains("<cid>31000</cid>"))
    }
}

// MARK: - Stubs

private struct ScriptedTransport: BcUdpTransport {
    enum CannedReply: Sendable {
        case success(dmap: (host: String, port: UInt16), dev: (host: String, port: UInt16), sid: UInt32)
        case rejected(code: Int)
        case successWithoutDmap
    }

    let reply: CannedReply
    private static let replySenderID: UInt32 = 0xCAFE_BABE

    func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        let payload: Data
        switch reply {
        case .success(let dmap, let dev, let sid):
            payload = DiscoveryXML.RendezvousReply(
                deviceLanEndpoint: DiscoveryXML.Endpoint(host: dev.host, port: dev.port),
                deviceMappedEndpoint: DiscoveryXML.Endpoint(host: dmap.host, port: dmap.port),
                relay: nil,
                sessionID: sid,
                responseCode: 0
            ).encode()
        case .rejected(let code):
            payload = DiscoveryXML.RendezvousReply(
                sessionID: 0,
                responseCode: code
            ).encode()
        case .successWithoutDmap:
            payload = DiscoveryXML.RendezvousReply(
                deviceLanEndpoint: DiscoveryXML.Endpoint(host: "192.168.1.42", port: 1),
                deviceMappedEndpoint: nil,
                sessionID: 1,
                responseCode: 0
            ).encode()
        }
        let cipher = DiscoveryXMLCrypto.encrypt(payload, offset: Self.replySenderID)
        return .disc(BcUdpDiscPacket(senderID: Self.replySenderID, payload: cipher))
    }
}

private actor CapturingTransport: BcUdpTransport {
    private(set) var captured: BcUdpPacket?
    private let inner: ScriptedTransport

    init(reply: ScriptedTransport.CannedReply) {
        self.inner = ScriptedTransport(reply: reply)
    }

    nonisolated func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        await store(packet)
        return try await inner.sendAndAwaitReply(packet, to: host, port: port, timeout: timeout)
    }

    private func store(_ p: BcUdpPacket) { captured = p }
    func lastSent() -> BcUdpPacket? { captured }
}

import Testing
import Foundation
@testable import ReolinkBcUdp

/// Tests for `DiscoveryXML` — the plaintext-XML codec for the
/// Reolink P2P discovery exchange. Wire schema validated against
/// the 2026-05-16 capture (decrypted with `DiscoveryXMLCrypto`).
@Suite("Discovery XML round-trip")
struct DiscoveryXMLTests {

    // MARK: - Request

    @Test("Lookup request encodes the wire-truth tag layout")
    func requestEncodes() throws {
        let req = DiscoveryXML.LookupRequest(uid: "95270H0I500W1NSQ")
        let bytes = req.encode()
        let xml = try #require(String(data: bytes, encoding: .utf8))
        #expect(xml.contains("<\(DiscoveryXML.Tag.root)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.clientRequest)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.uid)>95270H0I500W1NSQ</\(DiscoveryXML.Tag.uid)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.version)>3</\(DiscoveryXML.Tag.version)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.family)>6</\(DiscoveryXML.Tag.family)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.clientSource)>MAC</\(DiscoveryXML.Tag.clientSource)>"))
    }

    @Test("Lookup request round-trips encode → decode")
    func requestRoundTrip() throws {
        let original = DiscoveryXML.LookupRequest(
            uid: "DEADBEEF12345678",
            version: 3,
            family: 6,
            clientSource: "IOS"
        )
        let decoded = try #require(DiscoveryXML.LookupRequest.decode(from: original.encode()))
        #expect(decoded == original)
    }

    @Test("Decoding a payload missing the uid tag returns nil")
    func requestMissingUIDIsNil() {
        let bogus = Data("<P2P><C2M_Q><ver>3</ver></C2M_Q></P2P>".utf8)
        #expect(DiscoveryXML.LookupRequest.decode(from: bogus) == nil)
    }

    @Test("Decoding a request with empty uid returns nil")
    func requestEmptyUIDIsNil() {
        let bogus = Data("<P2P><C2M_Q><uid></uid></C2M_Q></P2P>".utf8)
        #expect(DiscoveryXML.LookupRequest.decode(from: bogus) == nil)
    }

    @Test("Decoding a request missing version/family defaults to 3/6")
    func requestVersionDefault() throws {
        let xml = Data("<P2P><C2M_Q><uid>X</uid></C2M_Q></P2P>".utf8)
        let decoded = try #require(DiscoveryXML.LookupRequest.decode(from: xml))
        #expect(decoded.version == 3)
        #expect(decoded.family == 6)
    }

    // MARK: - Response

    @Test("Response encodes only the candidates that are present")
    func responseOmitsAbsentCandidates() throws {
        let response = DiscoveryXML.LookupResponse(
            registration: DiscoveryXML.Endpoint(host: "203.0.113.10", port: 9000),
            responseCode: 0
        )
        let bytes = response.encode()
        let xml = try #require(String(data: bytes, encoding: .utf8))
        #expect(xml.contains("<\(DiscoveryXML.Tag.registration)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.ip)>203.0.113.10</\(DiscoveryXML.Tag.ip)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.port)>9000</\(DiscoveryXML.Tag.port)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.responseCode)>0</\(DiscoveryXML.Tag.responseCode)>"))
        #expect(!xml.contains("<\(DiscoveryXML.Tag.relay)>"))
    }

    @Test("Response round-trips registration + relay fields")
    func responseRoundTrip() throws {
        let original = DiscoveryXML.LookupResponse(
            registration: DiscoveryXML.Endpoint(host: "203.0.113.42", port: 12345),
            relay: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58101),
            responseCode: 0
        )
        let decoded = try #require(DiscoveryXML.LookupResponse.decode(from: original.encode()))
        #expect(decoded.registration == original.registration)
        #expect(decoded.relay == original.relay)
        #expect(decoded.responseCode == 0)
    }

    @Test("Response with no candidates is reported isEmpty")
    func responseEmpty() {
        let r = DiscoveryXML.LookupResponse(responseCode: -3)
        #expect(r.isEmpty)
        #expect(r.responseCode == -3)
    }

    @Test("Response with at least one candidate is not isEmpty")
    func responseNotEmpty() {
        let r = DiscoveryXML.LookupResponse(
            registration: DiscoveryXML.Endpoint(host: "1.2.3.4", port: 9000)
        )
        #expect(!r.isEmpty)
    }

    @Test("Decoding a payload without the M2C_Q_R wrapper returns nil")
    func responseMissingWrapperIsNil() {
        let bogus = Data("<P2P><reg><ip>1.2.3.4</ip><port>1</port></reg></P2P>".utf8)
        #expect(DiscoveryXML.LookupResponse.decode(from: bogus) == nil)
    }

    @Test("Decoding a real captured-success XML extracts the registration + relay")
    func decodesRealCapturedReply() throws {
        // Exact plaintext from the first decrypted success reply
        // in the 2026-05-16 pcap.
        let xmlString = "<P2P><M2C_Q_R>"
            + "<reg><ip>172.232.163.180</ip><port>58200</port></reg>"
            + "<relay><ip>172.232.163.180</ip><port>58101</port></relay>"
            + "<log><ip>172.232.163.180</ip><port>57850</port></log>"
            + "<t><ip>172.232.163.180</ip><port>9996</port></t>"
            + "<timer/><retry/><mtu>1350</mtu><debug>251658240</debug>"
            + "<ac>-1700607721</ac><rsp>0</rsp>"
            + "</M2C_Q_R></P2P>"
        let decoded = try #require(DiscoveryXML.LookupResponse.decode(from: Data(xmlString.utf8)))
        #expect(decoded.registration?.host == "172.232.163.180")
        #expect(decoded.registration?.port == 58200)
        #expect(decoded.relay?.host == "172.232.163.180")
        #expect(decoded.relay?.port == 58101)
        #expect(decoded.responseCode == 0)
    }

    @Test("Decoding a real captured not-registered XML extracts rsp=-3")
    func decodesRealCapturedFailureReply() throws {
        let xmlString = "<P2P><M2C_Q_R>"
            + "<timer/><retry><mrc>0</mrc></retry>"
            + "<debug>0</debug><ac>0</ac><rsp>-3</rsp>"
            + "</M2C_Q_R></P2P>"
        let decoded = try #require(DiscoveryXML.LookupResponse.decode(from: Data(xmlString.utf8)))
        #expect(decoded.registration == nil)
        #expect(decoded.relay == nil)
        #expect(decoded.responseCode == -3)
        #expect(decoded.isEmpty)
    }
}

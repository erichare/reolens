import Testing
import Foundation
@testable import ReolinkBcUdp

@Suite("Discovery XML round-trip")
struct DiscoveryXMLTests {

    // MARK: - Request

    @Test("Lookup request encodes the uid + clientID + priority into the documented tags")
    func requestEncodes() throws {
        let req = DiscoveryXML.LookupRequest(uid: "9876543210ABCDEF", clientID: "ab12cd34")
        let bytes = req.encode()
        let xml = try #require(String(data: bytes, encoding: .utf8))
        #expect(xml.contains("<\(DiscoveryXML.Tag.root)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.clientRequest)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.uid)>9876543210ABCDEF</\(DiscoveryXML.Tag.uid)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.clientID)>ab12cd34</\(DiscoveryXML.Tag.clientID)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.priority)>2</\(DiscoveryXML.Tag.priority)>"))
    }

    @Test("Lookup request round-trips encode → decode")
    func requestRoundTrip() throws {
        let original = DiscoveryXML.LookupRequest(uid: "DEADBEEF12345678", clientID: "test-client", priority: 3)
        let decoded = try #require(DiscoveryXML.LookupRequest.decode(from: original.encode()))
        #expect(decoded == original)
    }

    @Test("Decoding a payload missing the uid tag returns nil")
    func requestMissingUIDIsNil() {
        let bogus = Data("<P2P><C2D_C><cli>foo</cli></C2D_C></P2P>".utf8)
        #expect(DiscoveryXML.LookupRequest.decode(from: bogus) == nil)
    }

    @Test("Decoding a payload missing the priority tag defaults to 2")
    func requestPriorityDefault() throws {
        let xml = Data("<P2P><C2D_C><uid>X</uid><cli>c</cli></C2D_C></P2P>".utf8)
        let decoded = try #require(DiscoveryXML.LookupRequest.decode(from: xml))
        #expect(decoded.priority == 2)
    }

    // MARK: - Response

    @Test("Response encodes only the candidates that are present")
    func responseOmitsAbsentCandidates() throws {
        // Only wanV4 set; IPv6 / LAN / relay omitted so the
        // encoder must drop those tags entirely from the output.
        let response = DiscoveryXML.LookupResponse(
            uid: "ABCD",
            wanV4: DiscoveryXML.Endpoint(host: "203.0.113.10", port: 9000)
        )
        let bytes = response.encode()
        let xml = try #require(String(data: bytes, encoding: .utf8))
        #expect(xml.contains("<\(DiscoveryXML.Tag.wanIPv4)>203.0.113.10</\(DiscoveryXML.Tag.wanIPv4)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.wanPort)>9000</\(DiscoveryXML.Tag.wanPort)>"))
        // Absent fields don't appear in the XML — the client must
        // not interpret "<devLanIp></devLanIp>" as "empty LAN
        // address", so we just omit the tag entirely.
        #expect(!xml.contains("<\(DiscoveryXML.Tag.wanIPv6)>"))
        #expect(!xml.contains("<\(DiscoveryXML.Tag.lanIPv4)>"))
        #expect(!xml.contains("<\(DiscoveryXML.Tag.relayHost)>"))
    }

    @Test("Response round-trips every candidate field")
    func responseRoundTrip() throws {
        let original = DiscoveryXML.LookupResponse(
            uid: "FEED1234FACE5678",
            wanV4: DiscoveryXML.Endpoint(host: "203.0.113.42", port: 12345),
            wanV6: DiscoveryXML.Endpoint(host: "2001:db8::1", port: 0),
            lanV4: DiscoveryXML.Endpoint(host: "192.168.1.42", port: 9000),
            relay: DiscoveryXML.Endpoint(host: "relay-na-7.reolink.com", port: 8443)
        )
        let decoded = try #require(DiscoveryXML.LookupResponse.decode(from: original.encode()))
        #expect(decoded.uid == original.uid)
        #expect(decoded.wanV4 == original.wanV4)
        #expect(decoded.wanV6 == original.wanV6)
        #expect(decoded.lanV4 == original.lanV4)
        #expect(decoded.relay == original.relay)
    }

    @Test("Response with no candidates is reported isEmpty")
    func responseEmpty() {
        let r = DiscoveryXML.LookupResponse(uid: "AAAA")
        #expect(r.isEmpty)
    }

    @Test("Response with at least one candidate is not isEmpty")
    func responseNotEmpty() {
        let r = DiscoveryXML.LookupResponse(
            uid: "AAAA",
            wanV4: DiscoveryXML.Endpoint(host: "1.2.3.4", port: 9000)
        )
        #expect(!r.isEmpty)
    }

    @Test("Decoding a response missing the uid tag returns nil")
    func responseMissingUIDIsNil() {
        let bogus = Data("<P2P><D2C_C><devNatIp>1.2.3.4</devNatIp></D2C_C></P2P>".utf8)
        #expect(DiscoveryXML.LookupResponse.decode(from: bogus) == nil)
    }
}

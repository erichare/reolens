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
            rendezvous: DiscoveryXML.Endpoint(host: "203.0.113.10", port: 9000),
            responseCode: 0
        )
        let bytes = response.encode()
        let xml = try #require(String(data: bytes, encoding: .utf8))
        #expect(xml.contains("<\(DiscoveryXML.Tag.rendezvous)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.ip)>203.0.113.10</\(DiscoveryXML.Tag.ip)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.port)>9000</\(DiscoveryXML.Tag.port)>"))
        #expect(xml.contains("<\(DiscoveryXML.Tag.responseCode)>0</\(DiscoveryXML.Tag.responseCode)>"))
        #expect(!xml.contains("<\(DiscoveryXML.Tag.relay)>"))
    }

    @Test("Response round-trips registration + relay fields")
    func responseRoundTrip() throws {
        let original = DiscoveryXML.LookupResponse(
            rendezvous: DiscoveryXML.Endpoint(host: "203.0.113.42", port: 12345),
            relay: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58101),
            responseCode: 0
        )
        let decoded = try #require(DiscoveryXML.LookupResponse.decode(from: original.encode()))
        #expect(decoded.rendezvous == original.rendezvous)
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
            rendezvous: DiscoveryXML.Endpoint(host: "1.2.3.4", port: 9000)
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
        #expect(decoded.rendezvous?.host == "172.232.163.180")
        #expect(decoded.rendezvous?.port == 58200)
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
        #expect(decoded.rendezvous == nil)
        #expect(decoded.relay == nil)
        #expect(decoded.responseCode == -3)
        #expect(decoded.isEmpty)
    }

    // MARK: - Rendezvous (step 2)

    @Test("RendezvousRequest encodes the wire-truth C2R_C layout")
    func rendezvousRequestEncodes() throws {
        let req = DiscoveryXML.RendezvousRequest(
            uid: "9527000I500W1NSQ",
            clientHint: DiscoveryXML.Endpoint(host: "192.0.0.3", port: 19031),
            relayHint: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 58100),
            connectionID: 31000
        )
        let xml = try #require(String(data: req.encode(), encoding: .utf8))
        #expect(xml.contains("<C2R_C>"))
        #expect(xml.contains("<uid>9527000I500W1NSQ</uid>"))
        #expect(xml.contains("<cli><ip>192.0.0.3</ip><port>19031</port></cli>"))
        #expect(xml.contains("<relay><ip>172.232.163.180</ip><port>58100</port></relay>"))
        #expect(xml.contains("<cid>31000</cid>"))
        #expect(xml.contains("<family>6</family>"))
        #expect(xml.contains("<p>MAC</p>"))
        #expect(xml.contains("<r>3</r>"))
    }

    @Test("Decoding R2C_T (compact rendezvous reply) extracts dmap + dev + sid")
    func decodesRendezvousReplyT() throws {
        // Plaintext from the 2026-05-16 probe pcap.
        let xml = "<P2P><R2C_T>"
            + "<dev><ip>192.168.113.228</ip><port>52858</port></dev>"
            + "<dmap><ip>50.46.39.43</ip><port>52858</port></dmap>"
            + "<sid>7332712</sid><cid>31000</cid><rsp>0</rsp>"
            + "</R2C_T></P2P>"
        let decoded = try #require(DiscoveryXML.RendezvousReply.decode(from: Data(xml.utf8)))
        #expect(decoded.deviceLanEndpoint?.host == "192.168.113.228")
        #expect(decoded.deviceLanEndpoint?.port == 52858)
        #expect(decoded.deviceMappedEndpoint?.host == "50.46.39.43")
        #expect(decoded.deviceMappedEndpoint?.port == 52858)
        #expect(decoded.sessionID == 7_332_712)
        #expect(decoded.responseCode == 0)
    }

    @Test("Decoding R2C_C_R (full rendezvous reply) extracts dmap + dev + relay + sid")
    func decodesRendezvousReplyC() throws {
        let xml = "<P2P><R2C_C_R>"
            + "<dmap><ip>50.46.39.43</ip><port>52858</port></dmap>"
            + "<dev><ip>192.168.113.228</ip><port>52858</port></dev>"
            + "<relay><ip>172.232.163.180</ip><port>51188</port></relay>"
            + "<relayt><ip>172.232.163.180</ip><port>9997</port></relayt>"
            + "<nat>NULL</nat><sid>7332712</sid><rsp>0</rsp><ac>7332712</ac>"
            + "</R2C_C_R></P2P>"
        let decoded = try #require(DiscoveryXML.RendezvousReply.decode(from: Data(xml.utf8)))
        #expect(decoded.deviceMappedEndpoint?.host == "50.46.39.43")
        #expect(decoded.deviceMappedEndpoint?.port == 52858)
        #expect(decoded.deviceLanEndpoint?.host == "192.168.113.228")
        #expect(decoded.relay?.host == "172.232.163.180")
        #expect(decoded.relay?.port == 51188)
        #expect(decoded.sessionID == 7_332_712)
        #expect(decoded.responseCode == 0)
    }

    @Test("RendezvousReply round-trips through encode → decode")
    func rendezvousReplyRoundTrip() throws {
        let original = DiscoveryXML.RendezvousReply(
            deviceLanEndpoint: DiscoveryXML.Endpoint(host: "192.168.1.42", port: 12345),
            deviceMappedEndpoint: DiscoveryXML.Endpoint(host: "203.0.113.10", port: 12345),
            relay: DiscoveryXML.Endpoint(host: "172.232.163.180", port: 51188),
            sessionID: 7_332_712,
            responseCode: 0
        )
        let decoded = try #require(DiscoveryXML.RendezvousReply.decode(from: original.encode()))
        #expect(decoded.deviceLanEndpoint == original.deviceLanEndpoint)
        #expect(decoded.deviceMappedEndpoint == original.deviceMappedEndpoint)
        #expect(decoded.relay == original.relay)
        #expect(decoded.sessionID == original.sessionID)
        #expect(decoded.responseCode == original.responseCode)
    }

    @Test("Decoding payload without R2C wrapper returns nil")
    func rendezvousReplyMissingWrapperIsNil() {
        let bogus = Data("<P2P><something/></P2P>".utf8)
        #expect(DiscoveryXML.RendezvousReply.decode(from: bogus) == nil)
    }

    // MARK: - Punch probe (step 3)

    @Test("PunchProbe encodes the wire-truth C2D_T layout")
    func punchProbeEncodes() throws {
        let probe = DiscoveryXML.PunchProbe(
            sessionID: 7_332_712,
            connectionID: 31000
        )
        let xml = try #require(String(data: probe.encode(), encoding: .utf8))
        #expect(xml.contains("<C2D_T>"))
        #expect(xml.contains("<sid>7332712</sid>"))
        #expect(xml.contains("<conn>local</conn>"))
        #expect(xml.contains("<cid>31000</cid>"))
        #expect(xml.contains("<mtu>1350</mtu>"))
    }
}

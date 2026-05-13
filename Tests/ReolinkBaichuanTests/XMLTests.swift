import Testing
import Foundation
@testable import ReolinkBaichuan

/// 0.5.0 Theme B5 — XML helper tests for `BcXmlBody`. Closes a
/// previously-untested directory (`Sources/ReolinkBaichuan/XML/`).
@Suite("Baichuan XML helpers")
struct BcXmlTests {

    @Test("firstTagContent extracts a simple tag value")
    func firstTagContentSimple() {
        let xml = "<root><name>Front Door</name><port>9000</port></root>"
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "name") == "Front Door")
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "port") == "9000")
    }

    @Test("firstTagContent returns nil for an absent tag")
    func firstTagContentMissing() {
        let xml = "<root><name>Front Door</name></root>"
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "missing") == nil)
    }

    @Test("firstTagContent picks the first occurrence when a tag repeats")
    func firstTagContentRepeated() {
        let xml = "<root><alarm><type>md</type></alarm><alarm><type>people</type></alarm></root>"
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "type") == "md")
    }

    @Test("allBlocks returns every occurrence of a block tag")
    func allBlocksReturnsEvery() {
        let xml = """
        <AlarmEventList>
          <AlarmEvent version="1.1"><channelId>0</channelId><status>MD</status><AItype>none</AItype></AlarmEvent>
          <AlarmEvent version="1.1"><channelId>1</channelId><status>MD</status><AItype>people</AItype></AlarmEvent>
          <AlarmEvent version="1.1"><channelId>2</channelId><status>none</status><AItype>vehicle</AItype></AlarmEvent>
        </AlarmEventList>
        """
        let blocks = BcXmlBody.allBlocks(in: xml, tag: "AlarmEvent")
        #expect(blocks.count == 3)
        #expect(blocks[0].contains("<channelId>0</channelId>"))
        #expect(blocks[1].contains("<AItype>people</AItype>"))
        #expect(blocks[2].contains("<AItype>vehicle</AItype>"))
    }

    @Test("extractNonce pulls the nonce from a login response")
    func extractNonceFromLogin() {
        let xml = Data("""
        <body><Encryption version="1.1"><type>md5</type><nonce>abc123def456</nonce></Encryption></body>
        """.utf8)
        #expect(BcXmlBody.extractNonce(from: xml) == "abc123def456")
    }

    @Test("extractNonce returns nil when no nonce tag is present")
    func extractNonceMissing() {
        let xml = Data("<body><Result>ok</Result></body>".utf8)
        #expect(BcXmlBody.extractNonce(from: xml) == nil)
    }

    @Test("loginUserAndNet emits a body containing user + password hashes")
    func loginUserAndNetEmitsHashes() {
        let body = BcXmlBody.loginUserAndNet(usernameHash: "USERHASH", passwordHash: "PWDHASH")
        let xml = String(data: body, encoding: .utf8) ?? ""
        #expect(xml.contains("USERHASH"))
        #expect(xml.contains("PWDHASH"))
    }

    @Test("channelExtension emits a body referencing the channel number")
    func channelExtensionMentionsChannel() {
        let body = BcXmlBody.channelExtension(channel: 3)
        let xml = String(data: body, encoding: .utf8) ?? ""
        #expect(xml.contains("<channelId>3</channelId>") || xml.contains("3"))
    }
}

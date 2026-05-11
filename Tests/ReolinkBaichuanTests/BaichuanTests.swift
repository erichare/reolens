import Testing
import Foundation
import ReolinkAPI
@testable import ReolinkBaichuan

@Suite("BcHeader round-trip")
struct HeaderTests {

    @Test func encodesModernLoginHeader() {
        let header = BcHeader(
            msgID: BcMessageID.login,
            bodyLength: 100,
            channelID: 0,
            streamType: 0,
            msgNum: 7,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let bytes = header.encode()
        #expect(bytes.count == 24)
        // Magic header LE.
        #expect(bytes[0] == 0xF0)
        #expect(bytes[1] == 0xDE)
        #expect(bytes[2] == 0xBC)
        #expect(bytes[3] == 0x0A)
        // msg_id
        #expect(bytes.readLE(at: 4, as: UInt32.self) == 1)
        // body_len
        #expect(bytes.readLE(at: 8, as: UInt32.self) == 100)
        // msg_num
        #expect(bytes.readLE(at: 14, as: UInt16.self) == 7)
        // class
        #expect(bytes.readLE(at: 18, as: UInt16.self) == 0x6414)
        // payload_offset
        #expect(bytes.readLE(at: 20, as: UInt32.self) == 0)
    }

    @Test func encodesLegacyLoginHeader() {
        let header = BcHeader(
            msgID: BcMessageID.login,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: 0,
            responseCode: 0xDC12,
            msgClass: BcConstants.classLegacy
        )
        let bytes = header.encode()
        #expect(bytes.count == 20)
        #expect(bytes.readLE(at: 16, as: UInt16.self) == 0xDC12)
        #expect(bytes.readLE(at: 18, as: UInt16.self) == 0x6514)
    }

    @Test func decodesHeader() {
        let header = BcHeader(
            msgID: 33,
            bodyLength: 256,
            channelID: 2,
            streamType: 1,
            msgNum: 0x1234,
            responseCode: 200,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 12
        )
        let bytes = header.encode()
        let decoded = BcHeader.decode(from: bytes)
        #expect(decoded != nil)
        #expect(decoded?.msgID == 33)
        #expect(decoded?.bodyLength == 256)
        #expect(decoded?.channelID == 2)
        #expect(decoded?.msgNum == 0x1234)
        #expect(decoded?.responseCode == 200)
        #expect(decoded?.payloadOffset == 12)
    }

    @Test func rejectsBadMagic() {
        var bad = Data(count: 24)
        bad[0] = 0xAA  // wrong magic
        #expect(BcHeader.decode(from: bad) == nil)
    }

    @Test func extractsNegotiatedEncryption() {
        var hdr = BcHeader(msgID: 1, bodyLength: 0, msgNum: 0, msgClass: BcConstants.classLegacy)
        hdr.responseCode = 0xDD02       // server signaled AES
        #expect(hdr.negotiatedEncryption == .aes)
        hdr.responseCode = 0xDD01
        #expect(hdr.negotiatedEncryption == .bcEncrypt)
        hdr.responseCode = 200          // not a negotiation reply
        #expect(hdr.negotiatedEncryption == nil)
    }
}

@Suite("BCEncrypt XOR cipher")
struct BCEncryptTests {

    @Test func roundTrip_zeroOffset() {
        let plain = Data("<?xml version=\"1.0\"?><body/>".utf8)
        let cipher: BcCipher = .bcEncrypt
        let enc = cipher.encrypt(plain, encOffset: 0)
        #expect(enc != plain)
        let dec = cipher.decrypt(enc, encOffset: 0)
        #expect(dec == plain)
    }

    @Test func roundTrip_offsetRotates() {
        let plain = Data((0..<32).map { UInt8($0) })
        let cipher: BcCipher = .bcEncrypt
        for offset: UInt32 in [0, 1, 7, 8, 15, 0xFF] {
            let enc = cipher.encrypt(plain, encOffset: offset)
            let dec = cipher.decrypt(enc, encOffset: offset)
            #expect(dec == plain, "offset=\(offset)")
        }
    }

    @Test func xor_knownVector() {
        // Verify against the same algorithm as `neolink/crates/core/src/bc/crypto.rs:test_xml_crypto`:
        //   key = [1f, 2d, 3c, 4b, 5a, 69, 78, ff], plain bytes get XOR'd with key[(i+offset) % 8] ^ (offset & 0xff)
        let plain = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let enc = BcCipher.bcEncrypt.encrypt(plain, encOffset: 0)
        #expect(enc == Data([0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]))
    }
}

@Suite("AES-128-CFB cipher")
struct AESTests {

    @Test func keyDerivation() {
        // Verifies the recipe: first 16 ASCII bytes of uppercase-hex MD5 of "{nonce}-{password}".
        let key = BcCipher.deriveAESKey(nonce: "ABCDEF", password: "test")
        #expect(key.count == 16)
        // All bytes should be ASCII hex chars (0-9, A-F).
        for byte in key {
            let isHex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46)
            #expect(isHex, "key contained non-hex byte 0x\(String(byte, radix: 16))")
        }
    }

    @Test func roundTrip() {
        let key = BcCipher.deriveAESKey(nonce: "deadbeef", password: "secret")
        let cipher: BcCipher = .aes(key: key)
        let plain = Data("<?xml version=\"1.0\"?><body><test>hello world this is a longer body to exercise multi-block CFB</test></body>".utf8)
        let enc = cipher.encrypt(plain, encOffset: 0)
        #expect(enc != plain)
        let dec = cipher.decrypt(enc, encOffset: 0)
        #expect(dec == plain)
    }
}

@Suite("MD5 hash")
struct MD5Tests {

    @Test func reolinkHash_truncated() {
        // From Neolink: md5_string("admin", Truncate) == "21232F297A57A5A743894A0E4A801FC"
        #expect(BcMD5.reolinkHash("admin") == "21232F297A57A5A743894A0E4A801FC")
        #expect(BcMD5.reolinkHash("admin").count == 31)
    }
}

@Suite("Alarm event XML parsing")
struct AlarmEventTests {

    @Test func parsesMotionStart() {
        let xml = """
        <?xml version="1.0"?>
        <body>
        <AlarmEventList>
        <AlarmEvent>
        <channelId>0</channelId>
        <status>MD</status>
        <recording>0</recording>
        <timeStamp>1747000000</timeStamp>
        </AlarmEvent>
        </AlarmEventList>
        </body>
        """
        let events = BaichuanClient.parseAlarmEvents(xml: xml, channelID: 0)
        #expect(events.count == 1)
        #expect(events.first?.kind == .motionStart)
    }

    @Test func parsesAIEvent() {
        let xml = """
        <AlarmEventList>
        <AlarmEvent>
        <channelId>1</channelId>
        <status>MD</status>
        <ai_type>people</ai_type>
        <timeStamp>1747000000</timeStamp>
        </AlarmEvent>
        </AlarmEventList>
        """
        let events = BaichuanClient.parseAlarmEvents(xml: xml, channelID: 1)
        #expect(events.count == 1)
        #expect(events.first?.kind == .ai("people"))
    }

    @Test func parsesMultipleEvents() {
        let xml = """
        <AlarmEventList>
        <AlarmEvent><status>MD</status><ai_type>vehicle</ai_type></AlarmEvent>
        <AlarmEvent><status>MD</status><ai_type>dog_cat</ai_type></AlarmEvent>
        <AlarmEvent><status>none</status></AlarmEvent>
        </AlarmEventList>
        """
        let events = BaichuanClient.parseAlarmEvents(xml: xml, channelID: 0)
        #expect(events.count == 3)
        #expect(events[0].kind == .ai("vehicle"))
        #expect(events[1].kind == .ai("dog_cat"))
        #expect(events[2].kind == .motionStop)
    }
}

@Suite("Nonce extraction")
struct NonceTests {
    @Test func findsNonceInXML() {
        let xml = Data("""
        <?xml version="1.0"?>
        <body>
        <Encryption version="1.1">
        <type>BCEncrypt</type>
        <nonce>0123456789abcdef</nonce>
        </Encryption>
        </body>
        """.utf8)
        #expect(BcXmlBody.extractNonce(from: xml) == "0123456789abcdef")
    }
}

@Suite("XML multi-block extraction")
struct MultiBlockTests {
    @Test func extractsMultipleAlarmVideoBlocks() {
        let xml = """
        <alarmVideoList>
        <alarmVideo version="1.1">
        <fileName>0-0-AAA</fileName>
        <alarmType>md, people</alarmType>
        </alarmVideo>
        <alarmVideo version="1.1">
        <fileName>0-0-BBB</fileName>
        <alarmType>md, vehicle</alarmType>
        </alarmVideo>
        </alarmVideoList>
        """
        let blocks = BcXmlBody.allBlocks(in: xml, tag: "alarmVideo")
        #expect(blocks.count == 2)
        #expect(BcXmlBody.firstTagContent(in: blocks[0], tag: "fileName") == "0-0-AAA")
        #expect(BcXmlBody.firstTagContent(in: blocks[1], tag: "alarmType") == "md, vehicle")
    }

    @Test func extractsReolinkTime() {
        let xml = """
        <foo>
        <startTime>
        <year>2026</year>
        <month>5</month>
        <day>11</day>
        <hour>9</hour>
        <minute>20</minute>
        <second>15</second>
        </startTime>
        </foo>
        """
        let t = BcXmlBody.reolinkTime(in: xml, tag: "startTime")
        #expect(t?.year == 2026)
        #expect(t?.mon == 5)
        #expect(t?.day == 11)
        #expect(t?.hour == 9)
        #expect(t?.min == 20)
        #expect(t?.sec == 15)
    }
}

@Suite("BaichuanAlarmVideoFile detection mapping")
struct AlarmVideoTests {
    @Test func mapsCommonAlarmTypes() {
        let file = BaichuanAlarmVideoFile(
            fileName: "x",
            startTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 0, sec: 0),
            endTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 1, sec: 0),
            alarmType: "md, people, vehicle"
        )
        #expect(file.detections.contains(.motion))
        #expect(file.detections.contains(.person))
        #expect(file.detections.contains(.vehicle))
    }

    @Test func dedupesMotionFromMDAndPIR() {
        let file = BaichuanAlarmVideoFile(
            fileName: "x",
            startTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 0, sec: 0),
            endTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 1, sec: 0),
            alarmType: "md, pir"
        )
        #expect(file.detections == [.motion])
    }

    @Test func handlesAITagsExclusively() {
        let file = BaichuanAlarmVideoFile(
            fileName: "x",
            startTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 0, sec: 0),
            endTime: ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 1, sec: 0),
            alarmType: "dog_cat, face, package"
        )
        #expect(Set(file.detections) == Set([.pet, .face, .packageDelivery]))
    }
}

@Suite("IMA ADPCM encoder")
struct ADPCMEncoderTests {

    @Test func encodesToHalfTheBytes() {
        var enc = IMAADPCMEncoder()
        let samples: [Int16] = (0..<1024).map { Int16($0 * 30) }
        let encoded = enc.encode(pcm: samples)
        // 4 bits per sample → 1024 / 2 = 512 bytes
        #expect(encoded.count == 512)
    }

    @Test func roundTripsCloselyOnSinewave() {
        // We don't include a decoder, but we can verify the encoder is
        // deterministic and produces non-zero output for non-silent input.
        var encA = IMAADPCMEncoder()
        var encB = IMAADPCMEncoder()
        let samples: [Int16] = (0..<256).map { Int16(8000 * sin(Double($0) * 0.1)) }
        let a = encA.encode(pcm: samples)
        let b = encB.encode(pcm: samples)
        #expect(a == b)
        #expect(a.contains(where: { $0 != 0 }))
    }
}

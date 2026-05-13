import Testing
import Foundation
@testable import ReolinkBaichuan

/// 0.5.0 Theme B5 — wire-level round-trip tests for the Baichuan
/// header + message framing. Closes a previously-untested directory
/// (`Sources/ReolinkBaichuan/Wire/`). The fixtures here are the
/// minimum needed to lock the encode/decode contract — adding more
/// extensive scenarios is left to integration tests against a real
/// camera.
@Suite("Baichuan wire framing")
struct BcWireTests {

    @Test("BcHeader encode → decode round-trips for the modern class")
    func headerRoundTripModern() throws {
        let header = BcHeader(
            msgID: 0x0000_002A,
            bodyLength: 128,
            channelID: 3,
            streamType: 0,
            msgNum: 7,
            responseCode: 0,
            msgClass: BcConstants.classModern,
            payloadOffset: nil
        )
        let encoded = header.encode()
        #expect(encoded.count == 20)
        guard let decoded = BcHeader.decode(from: encoded) else {
            Issue.record("Header decode returned nil")
            return
        }
        #expect(decoded.msgID == header.msgID)
        #expect(decoded.bodyLength == header.bodyLength)
        #expect(decoded.channelID == header.channelID)
        #expect(decoded.msgNum == header.msgNum)
        #expect(decoded.msgClass == header.msgClass)
        #expect(decoded.payloadOffset == nil)
    }

    @Test("BcHeader encode → decode round-trips for the offset-carrying class")
    func headerRoundTripWithOffset() throws {
        let header = BcHeader(
            msgID: 273,
            bodyLength: 4096,
            channelID: 0,
            streamType: 0,
            msgNum: 12,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 1024
        )
        let encoded = header.encode()
        #expect(encoded.count == 24)
        guard let decoded = BcHeader.decode(from: encoded) else {
            Issue.record("Header decode returned nil")
            return
        }
        #expect(decoded.msgID == 273)
        #expect(decoded.payloadOffset == 1024)
        #expect(decoded.msgClass == BcConstants.classModernWithOffset)
    }

    @Test("BcHeader.decode rejects bytes that aren't a Baichuan magic")
    func headerRejectsForeignMagic() {
        // A buffer of zeroes is a common runtime garbage shape — the
        // decoder must reject it cleanly rather than treating zeros
        // as a valid header.
        let garbage = Data(repeating: 0, count: 24)
        #expect(BcHeader.decode(from: garbage) == nil)
    }

    @Test("BcHeader.decode returns nil when the buffer is shorter than the header")
    func headerRejectsShortBuffer() {
        let shortBuf = Data([0xF0, 0xDE, 0xBC, 0x0A, 0x00, 0x00]) // magic + 2 bytes, no full header
        #expect(BcHeader.decode(from: shortBuf) == nil)
    }

    @Test("BcMessage encodes with bodyLength matching the encrypted body")
    func messageBodyLengthMatchesEncodedBody() throws {
        let cipher: BcCipher = .unencrypted
        let header = BcHeader(
            msgID: 1,
            bodyLength: 0, // overwritten by encode
            channelID: 0,
            streamType: 0,
            msgNum: 1,
            responseCode: 0,
            msgClass: BcConstants.classModern,
            payloadOffset: nil
        )
        let body = Data("hello-baichuan".utf8)
        let msg = BcMessage(header: header, body: body)
        let wire = msg.encode(cipher: cipher)

        // The encoded wire is header (20 bytes) + body. We can pull
        // the body back out and verify the length stamp.
        #expect(wire.count == 20 + body.count)
        guard let decodedHeader = BcHeader.decode(from: wire) else {
            Issue.record("Couldn't decode header from encoded message")
            return
        }
        #expect(decodedHeader.bodyLength == UInt32(body.count))
    }
}

import Testing
import Foundation
@testable import ReolinkBcUdp

/// 0.7.0 Phase 1 — wire-level round-trip tests for the BcUdp
/// packet codec. The transport / discovery / NAT-traversal layers
/// will sit on top in later phases; this test target locks the
/// pure value-type encoding contract first so any future
/// regression is caught by `swift test --filter ReolinkBcUdpTests`
/// without spinning a network mock.
///
/// Companion design doc: `docs/remote-connectivity.md`.
@Suite("BcUdp wire framing")
struct BcUdpWireTests {

    // MARK: - Magic dispatch

    @Test("Each packet kind round-trips its magic via BcUdpPacketKind")
    func magicRoundTrip() {
        #expect(BcUdpPacketKind(magic: BcUdpConstants.magicDisc) == .disc)
        #expect(BcUdpPacketKind(magic: BcUdpConstants.magicData) == .data)
        #expect(BcUdpPacketKind(magic: BcUdpConstants.magicAck)  == .ack)
        #expect(BcUdpPacketKind(magic: 0xDEAD_BEEF) == nil)
    }

    // MARK: - Disc

    @Test("Disc packet encodes header at the documented offsets")
    func discHeaderLayout() throws {
        let packet = BcUdpDiscPacket(
            connectionID: 0x1122_3344,
            responseCode: 0x07,
            payload: Data("<P2P><req>lookup</req></P2P>".utf8)
        )
        let bytes = packet.encode()
        // Magic (BE u32)
        #expect(bytes.readBE(at: 0, as: UInt32.self) == BcUdpConstants.magicDisc)
        // Connection ID (BE u32)
        #expect(bytes.readBE(at: 4, as: UInt32.self) == 0x1122_3344)
        // Response code (u8)
        #expect(bytes[bytes.startIndex + 8] == 0x07)
        // Reserved (u8)
        #expect(bytes[bytes.startIndex + 9] == 0)
        // Payload length (BE u16)
        #expect(bytes.readBE(at: 10, as: UInt16.self) == UInt16(packet.payload.count))
        // Total length = 12-byte header + payload
        #expect(bytes.count == BcUdpConstants.HeaderLength.disc + packet.payload.count)
    }

    @Test("Disc packet round-trips encode → decode")
    func discRoundTrip() throws {
        let original = BcUdpDiscPacket(
            connectionID: 0xC0DE_F00D,
            responseCode: 0,
            payload: Data("<P2P><uid>9876543210ABCDEF</uid></P2P>".utf8)
        )
        let wire = original.encode()
        let result = try #require(BcUdpPacket.decode(from: wire))
        #expect(result.consumed == wire.count)
        guard case .disc(let decoded) = result.0 else {
            Issue.record("Expected .disc, got \(result.0.kind)")
            return
        }
        #expect(decoded == original)
    }

    @Test("Disc packet with empty payload still round-trips")
    func discEmptyPayloadRoundTrip() throws {
        let original = BcUdpDiscPacket(connectionID: 1, responseCode: 0, payload: Data())
        let wire = original.encode()
        #expect(wire.count == BcUdpConstants.HeaderLength.disc)
        let result = try #require(BcUdpPacket.decode(from: wire))
        guard case .disc(let decoded) = result.0 else {
            Issue.record("Expected .disc")
            return
        }
        #expect(decoded.payload.isEmpty)
        #expect(decoded == original)
    }

    // MARK: - Data

    @Test("Data packet encodes header at the documented offsets")
    func dataHeaderLayout() throws {
        let payload = Data((0..<64).map { UInt8($0) })
        let packet = BcUdpDataPacket(
            connectionID: 0xAAAA_BBBB,
            unknownA: 0xDEAD_BEEF,
            sequence: 0x0000_0042,
            payload: payload
        )
        let bytes = packet.encode()
        #expect(bytes.readBE(at: 0, as: UInt32.self) == BcUdpConstants.magicData)
        #expect(bytes.readBE(at: 4, as: UInt32.self) == 0xAAAA_BBBB)
        #expect(bytes.readBE(at: 8, as: UInt32.self) == 0xDEAD_BEEF)
        #expect(bytes.readBE(at: 12, as: UInt32.self) == 0x0000_0042)
        #expect(bytes.readBE(at: 16, as: UInt32.self) == 0)         // reserved
        #expect(bytes.readBE(at: 20, as: UInt16.self) == UInt16(payload.count))
        #expect(bytes.count == BcUdpConstants.HeaderLength.data + payload.count)
    }

    @Test("Data packet round-trips encode → decode")
    func dataRoundTrip() throws {
        // Use a payload that includes the Baichuan TCP magic so we
        // prove the BcUdp framing isn't confused by inner magic
        // bytes. The codec must not scan the payload.
        var payload = Data()
        payload.append(contentsOf: [0xF0, 0xDE, 0xBC, 0x0A])   // Baichuan LE magic
        payload.append(contentsOf: Array(repeating: UInt8(0x55), count: 128))
        let original = BcUdpDataPacket(
            connectionID: 1234,
            unknownA: 5678,
            sequence: 9001,
            payload: payload
        )
        let wire = original.encode()
        let result = try #require(BcUdpPacket.decode(from: wire))
        #expect(result.consumed == wire.count)
        guard case .data(let decoded) = result.0 else {
            Issue.record("Expected .data")
            return
        }
        #expect(decoded == original)
    }

    // MARK: - Ack

    @Test("Ack packet encodes header at the documented offsets")
    func ackHeaderLayout() throws {
        let bitmap = Data([0b1010_1100, 0b0000_0001])
        let packet = BcUdpAckPacket(
            connectionID: 0x7777_8888,
            cumulativeAck: 0x0000_0FFE,
            selectiveAckBitmap: bitmap
        )
        let bytes = packet.encode()
        #expect(bytes.readBE(at: 0, as: UInt32.self) == BcUdpConstants.magicAck)
        #expect(bytes.readBE(at: 4, as: UInt32.self) == 0x7777_8888)
        #expect(bytes.readBE(at: 8, as: UInt32.self) == 0x0000_0FFE)
        #expect(bytes.readBE(at: 12, as: UInt32.self) == 0)       // reserved
        #expect(bytes.readBE(at: 16, as: UInt16.self) == UInt16(bitmap.count))
        #expect(bytes.count == BcUdpConstants.HeaderLength.ack + bitmap.count)
    }

    @Test("Ack packet with no selective-ack bitmap round-trips")
    func ackWithoutBitmapRoundTrip() throws {
        let original = BcUdpAckPacket(connectionID: 42, cumulativeAck: 99)
        let wire = original.encode()
        #expect(wire.count == BcUdpConstants.HeaderLength.ack)
        let result = try #require(BcUdpPacket.decode(from: wire))
        guard case .ack(let decoded) = result.0 else {
            Issue.record("Expected .ack")
            return
        }
        #expect(decoded.selectiveAckBitmap.isEmpty)
        #expect(decoded == original)
    }

    @Test("Ack packet with selective-ack bitmap round-trips")
    func ackWithBitmapRoundTrip() throws {
        let original = BcUdpAckPacket(
            connectionID: 0xFEEDFACE,
            cumulativeAck: 100,
            selectiveAckBitmap: Data([0xFF, 0x80, 0x01])
        )
        let wire = original.encode()
        let result = try #require(BcUdpPacket.decode(from: wire))
        guard case .ack(let decoded) = result.0 else {
            Issue.record("Expected .ack")
            return
        }
        #expect(decoded == original)
    }

    // MARK: - Short / malformed buffers

    @Test("Decoding a buffer shorter than any header returns nil")
    func shortBufferRejected() {
        #expect(BcUdpPacket.decode(from: Data()) == nil)
        #expect(BcUdpPacket.decode(from: Data([0x2A, 0x87])) == nil)
    }

    @Test("Decoding an unknown magic returns nil rather than crashing")
    func unknownMagicRejected() {
        var bytes = Data()
        bytes.appendBE(UInt32(0xDEAD_BEEF))
        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 32))
        #expect(BcUdpPacket.decode(from: bytes) == nil)
    }

    @Test("Decoding a packet whose advertised length runs past the buffer returns nil")
    func truncatedPayloadRejected() {
        // Build a Disc header that claims a 100-byte payload, but
        // only provide 10 payload bytes. Caller should buffer more
        // bytes (we return nil) rather than read past the end.
        var bytes = Data()
        bytes.appendBE(BcUdpConstants.magicDisc)
        bytes.appendBE(UInt32(1))         // connID
        bytes.append(0)                    // responseCode
        bytes.append(0)                    // reserved
        bytes.appendBE(UInt16(100))        // claimed payload length
        bytes.append(contentsOf: Array(repeating: UInt8(0xAB), count: 10))
        #expect(BcUdpPacket.decode(from: bytes) == nil)
    }

    @Test("Decoding consumes exactly headerLength + payloadLength bytes (no over-read)")
    func decoderConsumesOnlyOnePacket() throws {
        let first = BcUdpDiscPacket(connectionID: 1, responseCode: 0, payload: Data([0x11, 0x22]))
        let second = BcUdpAckPacket(connectionID: 2, cumulativeAck: 7)
        var stream = first.encode()
        stream.append(second.encode())

        let r1 = try #require(BcUdpPacket.decode(from: stream))
        #expect(r1.consumed == BcUdpConstants.HeaderLength.disc + 2)
        guard case .disc = r1.0 else {
            Issue.record("Expected first packet to be .disc")
            return
        }

        // Slice off the consumed bytes and decode the next packet.
        // (BcUdp is over UDP, so packets arrive as discrete
        // datagrams in production — but the codec must be safe
        // for callers that buffer multiple packets in a single
        // Data, e.g. for unit tests or future relay framing.)
        let remaining = stream.subdata(in: r1.consumed..<stream.count)
        let r2 = try #require(BcUdpPacket.decode(from: remaining))
        #expect(r2.consumed == BcUdpConstants.HeaderLength.ack)
        guard case .ack = r2.0 else {
            Issue.record("Expected second packet to be .ack")
            return
        }
    }

    // MARK: - Constant sanity

    @Test("Packet-kind raw values match the magic constants")
    func packetKindRawValues() {
        #expect(BcUdpPacketKind.disc.rawValue == BcUdpConstants.magicDisc)
        #expect(BcUdpPacketKind.data.rawValue == BcUdpConstants.magicData)
        #expect(BcUdpPacketKind.ack.rawValue  == BcUdpConstants.magicAck)
    }

    @Test("Header-length constants match the byte counts produced by encode")
    func headerLengthsAreSelfConsistent() {
        let disc = BcUdpDiscPacket(connectionID: 0, responseCode: 0, payload: Data())
        let data = BcUdpDataPacket(connectionID: 0, unknownA: 0, sequence: 0, payload: Data())
        let ack  = BcUdpAckPacket(connectionID: 0, cumulativeAck: 0)
        #expect(disc.encode().count == BcUdpConstants.HeaderLength.disc)
        #expect(data.encode().count == BcUdpConstants.HeaderLength.data)
        #expect(ack.encode().count  == BcUdpConstants.HeaderLength.ack)
    }
}

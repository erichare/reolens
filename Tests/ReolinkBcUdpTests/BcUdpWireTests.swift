import Testing
import Foundation
@testable import ReolinkBcUdp

/// Wire-level round-trip tests for the BcUdp packet codec.
///
/// **Real-device fixtures included.** The tests below use header
/// bytes captured from a 2026-05-16 `p2p*.reolink.com` pcap (88
/// MB, 74k packets, Reolink macOS app cold-starting against a
/// camera off-LAN). One representative packet of each kind is
/// embedded verbatim so any future change to the codec is
/// validated against ground truth, not its own opinions.
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

    @Test("Magic constants match what the wire capture shows")
    func magicMatchesCapture() {
        // The exact byte sequences observed at offset 0 of every
        // matching packet in `reolink-p2p.pcap`.
        // Wire bytes: 3A CF 87 2A → LE u32 = 0x2A87CF3A
        #expect(BcUdpConstants.magicDisc == 0x2A87_CF3A)
        // Wire bytes: 10 CF 87 2A → LE u32 = 0x2A87CF10
        #expect(BcUdpConstants.magicData == 0x2A87_CF10)
        // Wire bytes: 20 CF 87 2A → LE u32 = 0x2A87CF20
        #expect(BcUdpConstants.magicAck  == 0x2A87_CF20)
    }

    // MARK: - Disc

    @Test("Disc packet encodes header at the documented offsets")
    func discHeaderLayout() throws {
        let packet = BcUdpDiscPacket(
            protocolFlag: 1,
            senderID: 0x003D_0B9B,
            requestToken: 0xA823_27D8,
            payload: Data("<P2P><req>lookup</req></P2P>".utf8)
        )
        let bytes = packet.encode()
        #expect(bytes.readLE(at: 0, as: UInt32.self) == BcUdpConstants.magicDisc)
        #expect(bytes.readLE(at: 4, as: UInt32.self) == UInt32(packet.payload.count))
        #expect(bytes.readLE(at: 8, as: UInt32.self) == 1)
        #expect(bytes.readLE(at: 12, as: UInt32.self) == 0x003D_0B9B)
        #expect(bytes.readLE(at: 16, as: UInt32.self) == 0xA823_27D8)
        #expect(bytes.count == BcUdpConstants.HeaderLength.disc + packet.payload.count)
    }

    @Test("Disc packet round-trips encode → decode")
    func discRoundTrip() throws {
        let original = BcUdpDiscPacket(
            protocolFlag: 1,
            senderID: 0xC0DE_F00D,
            requestToken: 0xCAFE_BABE,
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
        let original = BcUdpDiscPacket(senderID: 1, payload: Data())
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

    @Test("Decoder parses a captured Disc query header byte-for-byte")
    func discCapturedHeaderParses() throws {
        // 20 header bytes from the FIRST UDP/9999 discovery query
        // observed in `reolink-p2p.pcap`. Followed by 101 bytes
        // of XOR-obfuscated XML payload that the codec carries
        // opaquely.
        var bytes = Data([
            0x3a, 0xcf, 0x87, 0x2a,   // magic Disc
            0x65, 0x00, 0x00, 0x00,   // payload size = 101 (LE)
            0x01, 0x00, 0x00, 0x00,   // protocol flag
            0x9b, 0x0b, 0x3d, 0x00,   // sender id = 4_000_667
            0xd8, 0x27, 0x23, 0xa8    // request token = 0xa82327d8
        ])
        bytes.append(Data(repeating: 0xAA, count: 101))
        let result = try #require(BcUdpPacket.decode(from: bytes))
        #expect(result.consumed == 121)
        guard case .disc(let decoded) = result.0 else {
            Issue.record("Expected .disc")
            return
        }
        #expect(decoded.protocolFlag == 1)
        #expect(decoded.senderID == 4_000_667)
        #expect(decoded.requestToken == 0xA823_27D8)
        #expect(decoded.payload.count == 101)
    }

    // MARK: - Data

    @Test("Data packet encodes header at the documented offsets")
    func dataHeaderLayout() throws {
        let payload = Data((0..<64).map { UInt8($0) })
        let packet = BcUdpDataPacket(
            connectionID: 0x0000_02B5,
            sequence: 0x0000_0042,
            payload: payload
        )
        let bytes = packet.encode()
        #expect(bytes.readLE(at: 0, as: UInt32.self) == BcUdpConstants.magicData)
        #expect(bytes.readLE(at: 4, as: UInt32.self) == 0x0000_02B5)
        #expect(bytes.readLE(at: 8, as: UInt32.self) == 0)               // reserved
        #expect(bytes.readLE(at: 12, as: UInt32.self) == 0x0000_0042)
        #expect(bytes.readLE(at: 16, as: UInt32.self) == UInt32(payload.count))
        #expect(bytes.count == BcUdpConstants.HeaderLength.data + payload.count)
    }

    @Test("Data packet round-trips encode → decode (with embedded Baichuan magic)")
    func dataRoundTrip() throws {
        // Use a payload that includes the Baichuan TCP magic so we
        // prove the BcUdp framing isn't confused by inner magic
        // bytes. The codec must not scan the payload.
        var payload = Data()
        payload.append(contentsOf: [0xF0, 0xDE, 0xBC, 0x0A])   // Baichuan LE magic
        payload.append(contentsOf: Array(repeating: UInt8(0x55), count: 128))
        let original = BcUdpDataPacket(
            connectionID: 0x0000_02B5,
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

    @Test("Decoder parses a captured Data packet (first fragment of Baichuan login)")
    func dataCapturedHeaderParses() throws {
        // 40-byte Data packet captured from the bulk hole-punched
        // flow. Header says connectionID=0x2B5, sequence=0, 20
        // payload bytes. Payload starts with Baichuan TCP magic
        // (F0 DE BC 0A LE = 0x0ABCDEF0) followed by msg_id=1
        // (LE) — i.e. this is the first fragment of a Baichuan
        // login message sent over P2P.
        var bytes = Data([
            0x10, 0xcf, 0x87, 0x2a,   // magic Data
            0xb5, 0x02, 0x00, 0x00,   // connection_id = 0x2B5
            0x00, 0x00, 0x00, 0x00,   // reserved
            0x00, 0x00, 0x00, 0x00,   // sequence = 0
            0x14, 0x00, 0x00, 0x00    // payload size = 20
        ])
        // Payload: 20 bytes starting with Baichuan TCP magic
        bytes.append(contentsOf: [0xF0, 0xDE, 0xBC, 0x0A])
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])      // msg_id=1 LE
        bytes.append(Data(repeating: 0, count: 12))
        let result = try #require(BcUdpPacket.decode(from: bytes))
        #expect(result.consumed == 40)
        guard case .data(let decoded) = result.0 else {
            Issue.record("Expected .data")
            return
        }
        #expect(decoded.connectionID == 0x2B5)
        #expect(decoded.sequence == 0)
        #expect(decoded.payload.count == 20)
        // First 4 bytes of payload should be the Baichuan magic.
        #expect(decoded.payload.prefix(4) == Data([0xF0, 0xDE, 0xBC, 0x0A]))
    }

    // MARK: - Ack

    @Test("Ack packet encodes a 28-byte fixed header")
    func ackHeaderLayout() throws {
        let packet = BcUdpAckPacket(connectionID: 0x000A_25A8)
        let bytes = packet.encode()
        #expect(bytes.readLE(at: 0, as: UInt32.self) == BcUdpConstants.magicAck)
        #expect(bytes.readLE(at: 4, as: UInt32.self) == 0x000A_25A8)
        #expect(bytes.count == BcUdpConstants.HeaderLength.ack)
        // Default vocabulary is 20 zero bytes.
        #expect(bytes.suffix(20) == Data(count: 20))
    }

    @Test("Ack packet round-trips encode → decode")
    func ackRoundTrip() throws {
        // Use a non-zero vocab so we'd catch a byte-order error
        // even though we don't yet know what the bytes mean.
        let vocab = Data((1...20).map { UInt8($0) })
        let original = BcUdpAckPacket(
            connectionID: 0xFEED_FACE,
            ackVocabulary: vocab
        )
        let wire = original.encode()
        #expect(wire.count == BcUdpConstants.HeaderLength.ack)
        let result = try #require(BcUdpPacket.decode(from: wire))
        guard case .ack(let decoded) = result.0 else {
            Issue.record("Expected .ack")
            return
        }
        #expect(decoded == original)
    }

    @Test("Decoder parses a captured Ack packet (start-of-flow, all-zero vocab)")
    func ackCapturedParses() throws {
        let bytes = Data([
            0x20, 0xcf, 0x87, 0x2a,   // magic Ack
            0xa8, 0x25, 0x0a, 0x00,   // connection_id = 0xa25a8
            // 20 bytes of zero ack vocabulary
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ])
        let result = try #require(BcUdpPacket.decode(from: bytes))
        #expect(result.consumed == 28)
        guard case .ack(let decoded) = result.0 else {
            Issue.record("Expected .ack")
            return
        }
        #expect(decoded.connectionID == 0x000A_25A8)
        #expect(decoded.ackVocabulary == Data(count: 20))
    }

    @Test("Ack vocabulary shorter than 20 bytes is padded; longer is truncated")
    func ackVocabularyNormalises() {
        let short = BcUdpAckPacket(connectionID: 1, ackVocabulary: Data([0xAA, 0xBB]))
        #expect(short.ackVocabulary.count == 20)
        #expect(short.ackVocabulary.prefix(2) == Data([0xAA, 0xBB]))

        let long = BcUdpAckPacket(
            connectionID: 1,
            ackVocabulary: Data(repeating: 0xCC, count: 30)
        )
        #expect(long.ackVocabulary.count == 20)
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
        bytes.appendLE(UInt32(0xDEAD_BEEF))
        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 32))
        #expect(BcUdpPacket.decode(from: bytes) == nil)
    }

    @Test("Decoding a Disc whose advertised length runs past the buffer returns nil")
    func truncatedPayloadRejected() {
        // Build a Disc header that claims a 100-byte payload, but
        // only provide 10 payload bytes. Caller should buffer more
        // bytes (we return nil) rather than read past the end.
        var bytes = Data()
        bytes.appendLE(BcUdpConstants.magicDisc)
        bytes.appendLE(UInt32(100))          // claimed payload size
        bytes.appendLE(UInt32(1))            // protocol flag
        bytes.appendLE(UInt32(1))            // sender id
        bytes.appendLE(UInt32(0))            // request token
        bytes.append(contentsOf: Array(repeating: UInt8(0xAB), count: 10))
        #expect(BcUdpPacket.decode(from: bytes) == nil)
    }

    @Test("Decoding consumes exactly headerLength + payloadLength bytes (no over-read)")
    func decoderConsumesOnlyOnePacket() throws {
        let first = BcUdpDiscPacket(senderID: 1, payload: Data([0x11, 0x22]))
        let second = BcUdpAckPacket(connectionID: 2)
        var stream = first.encode()
        stream.append(second.encode())

        let r1 = try #require(BcUdpPacket.decode(from: stream))
        #expect(r1.consumed == BcUdpConstants.HeaderLength.disc + 2)
        guard case .disc = r1.0 else {
            Issue.record("Expected first packet to be .disc")
            return
        }

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
        let disc = BcUdpDiscPacket(senderID: 0, payload: Data())
        let data = BcUdpDataPacket(connectionID: 0, sequence: 0, payload: Data())
        let ack  = BcUdpAckPacket(connectionID: 0)
        #expect(disc.encode().count == BcUdpConstants.HeaderLength.disc)
        #expect(data.encode().count == BcUdpConstants.HeaderLength.data)
        #expect(ack.encode().count  == BcUdpConstants.HeaderLength.ack)
    }
}

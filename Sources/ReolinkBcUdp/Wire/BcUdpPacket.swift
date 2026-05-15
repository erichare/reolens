import Foundation

/// A decoded BcUdp packet — one of three kinds. Encoders flatten
/// back to wire bytes; decoders parse from the start of a `Data`
/// buffer and return the consumed byte count alongside the value.
///
/// All three kinds share a 4-byte big-endian magic prefix that
/// disambiguates them. After that, layouts diverge — see each
/// variant's struct doc for the exact field ordering.
public enum BcUdpPacket: Sendable, Hashable {
    case disc(BcUdpDiscPacket)
    case data(BcUdpDataPacket)
    case ack(BcUdpAckPacket)

    /// 4-byte magic that would appear on the wire for this packet.
    public var kind: BcUdpPacketKind {
        switch self {
        case .disc: .disc
        case .data: .data
        case .ack:  .ack
        }
    }

    /// Serialize to wire bytes. Round-trips with `decode(from:)`.
    public func encode() -> Data {
        switch self {
        case .disc(let p): p.encode()
        case .data(let p): p.encode()
        case .ack(let p):  p.encode()
        }
    }

    /// Parse a single packet from the start of `buffer`. Returns
    /// the decoded packet and the number of bytes consumed
    /// (`headerLength + payloadLength` for the kind), or nil
    /// when:
    ///
    /// - The buffer is shorter than any BcUdp header (caller
    ///   should buffer and retry).
    /// - The magic doesn't match any known kind (caller should
    ///   drop the bytes — *not* a BcUdp packet).
    /// - The advertised payload length would run past the
    ///   buffer (incomplete packet, retry on more bytes).
    public static func decode(from buffer: Data) -> (BcUdpPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.minimumPacketBytes else { return nil }
        guard let magic = buffer.readBEMagic(),
              let kind = BcUdpPacketKind(magic: magic) else { return nil }
        switch kind {
        case .disc:
            guard let (p, n) = BcUdpDiscPacket.decode(from: buffer) else { return nil }
            return (.disc(p), n)
        case .data:
            guard let (p, n) = BcUdpDataPacket.decode(from: buffer) else { return nil }
            return (.data(p), n)
        case .ack:
            guard let (p, n) = BcUdpAckPacket.decode(from: buffer) else { return nil }
            return (.ack(p), n)
        }
    }
}

// MARK: - Disc

/// Rendezvous / connection-setup packet. Used both when talking to
/// the Reolink `p2p*.reolink.com` discovery cluster (UID lookup,
/// candidate exchange) and during the per-camera hole-punch
/// handshake. The payload is an XML document (Reolink's `<P2P>`
/// schema); this codec carries it as opaque bytes so the higher
/// layers can parse it with their own XML reader.
///
/// Layout (big-endian, 12-byte header):
/// ```
///  0..3   magic         (u32) = 0x2A87CF20
///  4..7   connectionID  (u32) — opaque session identifier
///  8      responseCode  (u8)  — 0 on request; non-zero echoes
///                                back error / status from server
///  9      reserved      (u8)  — always 0 on the wire
/// 10..11  payloadLength (u16)
/// 12..    payload (XML bytes; not encrypted)
/// ```
public struct BcUdpDiscPacket: Sendable, Hashable {
    public var connectionID: UInt32
    public var responseCode: UInt8
    public var payload: Data

    public init(connectionID: UInt32, responseCode: UInt8 = 0, payload: Data) {
        self.connectionID = connectionID
        self.responseCode = responseCode
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.disc + payload.count)
        out.appendBE(BcUdpConstants.magicDisc)
        out.appendBE(connectionID)
        out.append(responseCode)
        out.append(0)   // reserved
        out.appendBE(UInt16(payload.count))
        out.append(payload)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpDiscPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.disc,
              let magic = buffer.readBE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicDisc,
              let connectionID = buffer.readBE(at: 4, as: UInt32.self),
              let payloadLen = buffer.readBE(at: 10, as: UInt16.self)
        else { return nil }
        let responseCode = buffer[buffer.startIndex + 8]
        let total = BcUdpConstants.HeaderLength.disc + Int(payloadLen)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + BcUdpConstants.HeaderLength.disc
        let payloadEnd = payloadStart + Int(payloadLen)
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        return (
            BcUdpDiscPacket(
                connectionID: connectionID,
                responseCode: responseCode,
                payload: payload
            ),
            total
        )
    }
}

// MARK: - Data

/// Carries a slice of a Baichuan TCP message. Large Baichuan
/// messages (e.g. a `msg_id=3` video frame several KB long) split
/// across multiple `Data` packets; the receiver reassembles by
/// `sequence`, then feeds the concatenated bytes through
/// `ReolinkBaichuan.BcMessage.decode(from:cipher:)` as if they had
/// arrived over TCP. The `unknownA` field is preserved verbatim —
/// neolink labels it `unknown_a` (used by Reolink for some kind of
/// connection cookie that we don't need to interpret).
///
/// Layout (big-endian, 22-byte header):
/// ```
///  0..3   magic         (u32) = 0x2A87CF01
///  4..7   connectionID  (u32) — assigned during the Disc handshake
///  8..11  unknownA      (u32) — neolink `unknown_a`; round-tripped
/// 12..15  sequence      (u32) — packet seq; receiver acks by this
/// 16..19  reserved      (u32) — always 0 on the wire
/// 20..21  payloadLength (u16)
/// 22..    payload (Baichuan message slice; not BcUdp-encrypted —
///                  the Baichuan layer handles its own AES)
/// ```
public struct BcUdpDataPacket: Sendable, Hashable {
    public var connectionID: UInt32
    public var unknownA: UInt32
    public var sequence: UInt32
    public var payload: Data

    public init(connectionID: UInt32, unknownA: UInt32 = 0, sequence: UInt32, payload: Data) {
        self.connectionID = connectionID
        self.unknownA = unknownA
        self.sequence = sequence
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.data + payload.count)
        out.appendBE(BcUdpConstants.magicData)
        out.appendBE(connectionID)
        out.appendBE(unknownA)
        out.appendBE(sequence)
        out.appendBE(UInt32(0))   // reserved
        out.appendBE(UInt16(payload.count))
        out.append(payload)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpDataPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.data,
              let magic = buffer.readBE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicData,
              let connectionID = buffer.readBE(at: 4, as: UInt32.self),
              let unknownA = buffer.readBE(at: 8, as: UInt32.self),
              let sequence = buffer.readBE(at: 12, as: UInt32.self),
              let payloadLen = buffer.readBE(at: 20, as: UInt16.self)
        else { return nil }
        let total = BcUdpConstants.HeaderLength.data + Int(payloadLen)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + BcUdpConstants.HeaderLength.data
        let payloadEnd = payloadStart + Int(payloadLen)
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        return (
            BcUdpDataPacket(
                connectionID: connectionID,
                unknownA: unknownA,
                sequence: sequence,
                payload: payload
            ),
            total
        )
    }
}

// MARK: - Ack

/// Acknowledges `Data` sequence numbers. The `cumulativeAck`
/// field is "all seq numbers up to and including this value have
/// been received"; the payload is an optional selective-ack
/// bitmap (one bit per seq beyond cumulative, LSB = next-after-
/// cumulative). The retransmit / out-of-order layer above the
/// codec interprets the bitmap; this codec just carries it.
///
/// Layout (big-endian, 18-byte header):
/// ```
///  0..3   magic          (u32) = 0x2A87CF10
///  4..7   connectionID   (u32)
///  8..11  cumulativeAck  (u32) — highest contiguous seq received
/// 12..15  reserved       (u32) — always 0 on the wire
/// 16..17  payloadLength  (u16) — bitmap byte count (often 0)
/// 18..    payload (selective-ack bitmap)
/// ```
public struct BcUdpAckPacket: Sendable, Hashable {
    public var connectionID: UInt32
    public var cumulativeAck: UInt32
    public var selectiveAckBitmap: Data

    public init(connectionID: UInt32, cumulativeAck: UInt32, selectiveAckBitmap: Data = Data()) {
        self.connectionID = connectionID
        self.cumulativeAck = cumulativeAck
        self.selectiveAckBitmap = selectiveAckBitmap
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.ack + selectiveAckBitmap.count)
        out.appendBE(BcUdpConstants.magicAck)
        out.appendBE(connectionID)
        out.appendBE(cumulativeAck)
        out.appendBE(UInt32(0))   // reserved
        out.appendBE(UInt16(selectiveAckBitmap.count))
        out.append(selectiveAckBitmap)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpAckPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.ack,
              let magic = buffer.readBE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicAck,
              let connectionID = buffer.readBE(at: 4, as: UInt32.self),
              let cumulativeAck = buffer.readBE(at: 8, as: UInt32.self),
              let bitmapLen = buffer.readBE(at: 16, as: UInt16.self)
        else { return nil }
        let total = BcUdpConstants.HeaderLength.ack + Int(bitmapLen)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + BcUdpConstants.HeaderLength.ack
        let payloadEnd = payloadStart + Int(bitmapLen)
        let bitmap = buffer.subdata(in: payloadStart..<payloadEnd)
        return (
            BcUdpAckPacket(
                connectionID: connectionID,
                cumulativeAck: cumulativeAck,
                selectiveAckBitmap: bitmap
            ),
            total
        )
    }
}

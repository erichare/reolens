import Foundation

/// A decoded BcUdp packet — one of three kinds. Encoders flatten
/// back to wire bytes; decoders parse from the start of a `Data`
/// buffer and return the consumed byte count alongside the value.
///
/// All three kinds share a 4-byte little-endian magic prefix that
/// disambiguates them. After that, layouts diverge — see each
/// variant's struct doc for the exact field ordering.
///
/// Reference for the layouts: `thirtythreeforty/neolink`'s
/// `crates/core/src/bcudp/` plus a May 2026 wire capture against
/// `p2p*.reolink.com` (74k packets, ~88 MB pcap) that confirmed
/// magic values, header sizes, and field offsets. The
/// non-discriminator fields whose semantics aren't yet pinned to
/// observable behaviour are round-tripped verbatim with neutral
/// names + comments documenting what was observed.
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
        guard let magic = buffer.readLEMagic(),
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

/// Rendezvous / connection-setup packet. Used both when talking
/// to the Reolink `p2p*.reolink.com` discovery cluster on UDP/9999
/// (UID lookup, candidate exchange) and during the per-camera
/// hole-punch handshake. The payload is XML — the wire capture
/// shows it XOR-obfuscated with Reolink's rotating cipher; the
/// codec here treats it as opaque bytes so the higher
/// `DiscoveryXML` layer can decrypt + parse with its own reader.
///
/// Layout (little-endian, 20-byte header):
/// ```
///  0..3   magic         (u32) = 0x2A87CF3A
///  4..7   payloadSize   (u32) — bytes following the header
///  8..11  protocolFlag  (u32) — observed value 1 in every
///                                captured Disc packet; likely a
///                                protocol version
/// 12..15  senderID      (u32) — sender's session identifier
/// 16..19  requestToken  (u32) — per-request nonce; the server
///                                echoes it back in the matching
///                                reply (so the client can match
///                                async replies to requests)
/// 20..    payload (XOR-obfuscated XML)
/// ```
public struct BcUdpDiscPacket: Sendable, Hashable {
    public var protocolFlag: UInt32
    public var senderID: UInt32
    public var requestToken: UInt32
    public var payload: Data

    public init(
        protocolFlag: UInt32 = 1,
        senderID: UInt32,
        requestToken: UInt32 = 0,
        payload: Data
    ) {
        self.protocolFlag = protocolFlag
        self.senderID = senderID
        self.requestToken = requestToken
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.disc + payload.count)
        out.appendLE(BcUdpConstants.magicDisc)
        out.appendLE(UInt32(payload.count))
        out.appendLE(protocolFlag)
        out.appendLE(senderID)
        out.appendLE(requestToken)
        out.append(payload)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpDiscPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.disc,
              let magic = buffer.readLE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicDisc,
              let payloadSize = buffer.readLE(at: 4, as: UInt32.self),
              let protocolFlag = buffer.readLE(at: 8, as: UInt32.self),
              let senderID = buffer.readLE(at: 12, as: UInt32.self),
              let requestToken = buffer.readLE(at: 16, as: UInt32.self)
        else { return nil }
        let total = BcUdpConstants.HeaderLength.disc + Int(payloadSize)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + BcUdpConstants.HeaderLength.disc
        let payloadEnd = payloadStart + Int(payloadSize)
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        return (
            BcUdpDiscPacket(
                protocolFlag: protocolFlag,
                senderID: senderID,
                requestToken: requestToken,
                payload: payload
            ),
            total
        )
    }
}

// MARK: - Data

/// Carries one fragment of a Baichuan message. Large Baichuan
/// messages (e.g. a `msg_id=3` video frame several KB long) split
/// across multiple `Data` packets; the receiver reassembles by
/// `sequence`, then feeds the concatenated bytes through
/// `ReolinkBaichuan.BcMessage.decode(from:cipher:)` exactly as if
/// they had arrived over TCP. The wire capture confirms this:
/// the first fragment of any Baichuan message has the Baichuan
/// TCP magic (`0xABCDEF0`, little-endian `F0 DE BC 0A`) at offset
/// 20 of the UDP payload — directly after the BcUdp header.
///
/// Layout (little-endian, 20-byte header):
/// ```
///  0..3   magic         (u32) = 0x2A87CF10
///  4..7   connectionID  (u32) — per-session token from handshake
///  8..11  reserved      (u32) — always 0 in the capture
/// 12..15  sequence      (u32) — monotonic per-message fragment
///                                index; receiver acks by this
/// 16..19  payloadSize   (u32) — this fragment's byte count
///                                (NOT the total message size —
///                                the receiver discovers that by
///                                parsing the Baichuan header in
///                                the first fragment)
/// 20..    payload (one fragment of a Baichuan message; carries
///                  the Baichuan layer's own AES encryption — not
///                  BcUdp-encrypted)
/// ```
public struct BcUdpDataPacket: Sendable, Hashable {
    public var connectionID: UInt32
    public var sequence: UInt32
    public var payload: Data

    public init(connectionID: UInt32, sequence: UInt32, payload: Data) {
        self.connectionID = connectionID
        self.sequence = sequence
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.data + payload.count)
        out.appendLE(BcUdpConstants.magicData)
        out.appendLE(connectionID)
        out.appendLE(UInt32(0))           // reserved
        out.appendLE(sequence)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpDataPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.data,
              let magic = buffer.readLE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicData,
              let connectionID = buffer.readLE(at: 4, as: UInt32.self),
              let sequence = buffer.readLE(at: 12, as: UInt32.self),
              let payloadSize = buffer.readLE(at: 16, as: UInt32.self)
        else { return nil }
        let total = BcUdpConstants.HeaderLength.data + Int(payloadSize)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + BcUdpConstants.HeaderLength.data
        let payloadEnd = payloadStart + Int(payloadSize)
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        return (
            BcUdpDataPacket(
                connectionID: connectionID,
                sequence: sequence,
                payload: payload
            ),
            total
        )
    }
}

// MARK: - Ack

/// Acknowledges `Data` fragments. The wire capture shows Ack as
/// a fixed 28-byte packet — magic + connectionID + 20 bytes of
/// ack vocabulary that, in the captured start-of-flow samples,
/// were all zero. The wire-level meanings of the trailing 20
/// bytes (cumulative-ack value, selective-ack bitmap, possible
/// echo of last Data sequence number) will sharpen once Phase
/// 3d.2 drives enough traffic to make them vary; for now the
/// codec carries them as opaque bytes so round-trip is exact.
///
/// Layout (little-endian, 28-byte fixed header):
/// ```
///  0..3   magic         (u32) = 0x2A87CF20
///  4..7   connectionID  (u32)
///  8..27  ackVocab      (20 bytes) — observed all-zero in
///                                     start-of-flow Acks;
///                                     reassessed in 3d.2
/// ```
public struct BcUdpAckPacket: Sendable, Hashable {
    public var connectionID: UInt32
    /// 20 bytes following the connectionID. Carried verbatim so
    /// encode-then-decode round-trips byte-identical. Phase 3d.2
    /// will replace this with named fields once we've watched
    /// the bytes vary against real traffic.
    public var ackVocabulary: Data

    public init(connectionID: UInt32, ackVocabulary: Data = Data(count: 20)) {
        self.connectionID = connectionID
        // Pad or truncate to exactly 20 bytes to keep the fixed
        // header size invariant. Callers that hand in shorter or
        // longer buffers get the canonical 20.
        if ackVocabulary.count == 20 {
            self.ackVocabulary = ackVocabulary
        } else if ackVocabulary.count < 20 {
            self.ackVocabulary = ackVocabulary + Data(count: 20 - ackVocabulary.count)
        } else {
            self.ackVocabulary = ackVocabulary.prefix(20)
        }
    }

    public func encode() -> Data {
        var out = Data(capacity: BcUdpConstants.HeaderLength.ack)
        out.appendLE(BcUdpConstants.magicAck)
        out.appendLE(connectionID)
        out.append(ackVocabulary)
        return out
    }

    public static func decode(from buffer: Data) -> (BcUdpAckPacket, consumed: Int)? {
        guard buffer.count >= BcUdpConstants.HeaderLength.ack,
              let magic = buffer.readLE(at: 0, as: UInt32.self),
              magic == BcUdpConstants.magicAck,
              let connectionID = buffer.readLE(at: 4, as: UInt32.self)
        else { return nil }
        let vocabStart = buffer.startIndex + 8
        let vocabEnd = buffer.startIndex + BcUdpConstants.HeaderLength.ack
        let vocab = buffer.subdata(in: vocabStart..<vocabEnd)
        return (
            BcUdpAckPacket(connectionID: connectionID, ackVocabulary: vocab),
            BcUdpConstants.HeaderLength.ack
        )
    }
}

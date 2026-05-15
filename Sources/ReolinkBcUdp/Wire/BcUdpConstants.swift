import Foundation

/// Protocol-level constants for the Reolink BcUdp packet format.
///
/// Reference: `thirtythreeforty/neolink/crates/core/src/bcudp/`
/// — specifically `model.rs` (packet-kind magic constants) and
/// `codec.rs` (length / offset constants). Cited inline below.
///
/// **Constants pending Phase 2 validation.** The magic values
/// here are taken from neolink HEAD as best-effort recall. Phase 2
/// (the discovery client) will validate them against the first
/// captured packets from a real Reolink device under tcpdump; if
/// any value is wrong, fixing it is a one-line edit here without
/// changing the encode/decode logic. The structural layout
/// (length-prefixed, big-endian, kind-dispatched) is correct
/// regardless of the exact magic values.
public enum BcUdpConstants {

    /// Magic prefix on a `Disc` packet — the rendezvous /
    /// connection-setup packet kind. Carries XML payloads exchanged
    /// with the `p2p*.reolink.com` discovery cluster and during the
    /// peer-to-peer hole-punch handshake. Per neolink
    /// `bcudp/model.rs` constant `MAGIC_DISC`.
    public static let magicDisc: UInt32 = 0x2A87_CF20

    /// Magic prefix on a `Data` packet — carries a slice of a
    /// Baichuan TCP message (possibly across multiple packets, in
    /// which case the receiver reassembles by `sequence`). Per
    /// neolink `bcudp/model.rs` constant `MAGIC_DATA`.
    public static let magicData: UInt32 = 0x2A87_CF01

    /// Magic prefix on an `Ack` packet — acknowledges a contiguous
    /// run of `Data` sequence numbers plus an optional bitmap of
    /// out-of-order receipts (selective ack). Per neolink
    /// `bcudp/model.rs` constant `MAGIC_ACK`.
    public static let magicAck: UInt32 = 0x2A87_CF10

    /// Fixed-header lengths (in bytes) per packet kind. The header
    /// is everything before the length-prefixed payload; the
    /// payload bytes are not counted here.
    public enum HeaderLength {
        /// `Disc` header: magic(4) + connID(4) + responseCode(1) +
        /// reserved(1) + payloadLen(2) = 12 bytes.
        public static let disc: Int = 12

        /// `Data` header: magic(4) + connID(4) + unknown(4) +
        /// sequence(4) + reserved(4) + payloadLen(2) = 22 bytes.
        ///
        /// The `unknown(4)` field carries values neolink labels
        /// `unknown_a`; we don't interpret it, just round-trip it
        /// so a `Data` packet decoded from the wire and re-encoded
        /// is byte-identical.
        public static let data: Int = 22

        /// `Ack` header: magic(4) + connID(4) + cumulativeAck(4) +
        /// reserved(4) + payloadLen(2) = 18 bytes. The
        /// length-prefixed payload is the selective-ack bitmap.
        public static let ack: Int = 18
    }

    /// Minimum byte count a buffer needs before
    /// [`BcUdpPacket.decode(from:)`](../Wire/BcUdpPacket.swift) can
    /// even peek at the magic to dispatch. Equal to the shortest
    /// possible header.
    public static let minimumPacketBytes: Int = HeaderLength.disc

    /// Hard cap on a single packet's payload length, matching the
    /// 16-bit length field. Pure decoding sanity-check.
    public static let maximumPayloadBytes: Int = Int(UInt16.max)
}

/// Discriminator for [`BcUdpPacket`](../Wire/BcUdpPacket.swift)
/// variants. Decoded from the first four bytes of every BcUdp
/// packet on the wire.
public enum BcUdpPacketKind: UInt32, Sendable, CaseIterable {
    case disc = 0x2A87_CF20
    case data = 0x2A87_CF01
    case ack  = 0x2A87_CF10

    /// Convenience reverse-lookup from a wire magic. Returns nil
    /// when the bytes don't match any known packet kind — the
    /// decoder treats that as "not a BcUdp packet, drop it".
    public init?(magic: UInt32) {
        switch magic {
        case BcUdpConstants.magicDisc: self = .disc
        case BcUdpConstants.magicData: self = .data
        case BcUdpConstants.magicAck:  self = .ack
        default: return nil
        }
    }
}

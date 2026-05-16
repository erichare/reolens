import Foundation

/// Protocol-level constants for the Reolink BcUdp packet format.
///
/// **Validated against a real `p2p*.reolink.com` exchange on
/// 2026-05-16** (88 MB pcap from `reolink-mac-app → camera off-LAN`,
/// 74k packets). The three magic values, the header sizes, and the
/// fact that `Data` packets carry standard Baichuan TCP-framed
/// messages (magic `0xABCDEF0` at offset 20 of the UDP payload) are
/// all confirmed against the wire. Field-level interpretation of
/// the Disc/Data/Ack headers past the discriminator + size + sequence
/// is documented best-effort — Phase 3d.2 will sharpen it as the
/// hole-punch state machine lands.
///
/// Reference: `thirtythreeforty/neolink/crates/core/src/bcudp/`
/// — model.rs for the magic constants, codec.rs for header
/// layouts. neolink's values were used as the starting point;
/// the wire capture corrected three magics (my Phase 1
/// best-effort recall was wrong on all three).
public enum BcUdpConstants {

    /// Magic prefix on a `Disc` packet — discovery + hole-punch
    /// rendezvous. The 4-byte sequence on the wire is
    /// `3A CF 87 2A` (little-endian u32 = `0x2A87CF3A`). Used
    /// both in client → `p2p*.reolink.com:9999` lookup queries
    /// and in the punch-through probes that establish the data
    /// channel.
    public static let magicDisc: UInt32 = 0x2A87_CF3A

    /// Magic prefix on a `Data` packet — carries one fragment
    /// of a Baichuan message across the hole-punched UDP
    /// channel. The 4-byte sequence on the wire is
    /// `10 CF 87 2A` (little-endian u32 = `0x2A87CF10`). Bulk
    /// of the post-handshake traffic; ~91% of packets in the
    /// capture were Data.
    public static let magicData: UInt32 = 0x2A87_CF10

    /// Magic prefix on an `Ack` packet — acknowledges a run
    /// of `Data` sequence numbers. The 4-byte sequence on the
    /// wire is `20 CF 87 2A` (little-endian u32 = `0x2A87CF20`).
    /// Sent at roughly 1:10 ratio to `Data` in the capture
    /// (~9% of packets).
    public static let magicAck: UInt32 = 0x2A87_CF20

    /// Fixed-header lengths (in bytes) per packet kind. Each
    /// header is followed by an optional payload (Disc carries
    /// XML; Data carries a Baichuan-message fragment; Ack
    /// typically carries no payload). The size field at
    /// header offset 4 names the *full Baichuan message size*
    /// for Data, not just this packet's contribution — the
    /// per-fragment byte count lives at offset 16.
    public enum HeaderLength {
        /// `Disc` header: 5 × u32 = 20 bytes.
        ///
        /// Observed layout (from the captured Disc queries
        /// at UDP/9999):
        ///
        /// - `[0..4)`   `u32` magic (`0x2A87CF3A`)
        /// - `[4..8)`   `u32` payload byte count
        /// - `[8..12)`  `u32` constant (`0x00000001` in every
        ///              captured packet — likely a version /
        ///              protocol identifier)
        /// - `[12..16)` `u32` sender ID or session token
        /// - `[16..20)` `u32` per-request token / nonce
        public static let disc: Int = 20

        /// `Data` header: 5 × u32 = 20 bytes.
        ///
        /// Observed layout (from the post-handshake bulk
        /// flow):
        ///
        /// - `[0..4)`   `u32` magic (`0x2A87CF10`)
        /// - `[4..8)`   `u32` total Baichuan-message size
        ///              across all fragments (drives the
        ///              reassembly buffer's allocation)
        /// - `[8..12)`  `u32` constant `0` (reserved /
        ///              unused on the wire)
        /// - `[12..16)` `u32` fragment sequence number,
        ///              monotonically increasing per message
        /// - `[16..20)` `u32` this packet's payload byte count
        ///              (i.e. how many of the total-size
        ///              bytes ride in this fragment)
        ///
        /// Payload begins at offset 20 and contains the
        /// next chunk of the Baichuan TCP framing — the
        /// first fragment of any Baichuan message has
        /// magic `0xABCDEF0` at offset 20 of the UDP payload,
        /// directly confirming the TCP-equivalent format.
        public static let data: Int = 20

        /// `Ack` header: 7 × u32 = 28 bytes.
        ///
        /// Observed layout (from the post-handshake bulk
        /// flow's ack pattern):
        ///
        /// - `[0..4)`   `u32` magic (`0x2A87CF20`)
        /// - `[4..8)`   `u32` connection ID (matches the
        ///              Data packet's `total_size`-shaped
        ///              field — likely a session identifier
        ///              minted during the handshake)
        /// - `[8..28)`  20 bytes — selective-ack bitmap +
        ///              cumulative-ack fields. All zero in
        ///              the start-of-flow Acks captured;
        ///              Phase 3d.2 will pin individual
        ///              meanings once the state machine sends
        ///              Data sequences large enough to
        ///              exercise the ack vocabulary.
        public static let ack: Int = 28
    }

    /// Minimum byte count a buffer needs before
    /// [`BcUdpPacket.decode(from:)`](../Wire/BcUdpPacket.swift) can
    /// even peek at the magic to dispatch. Equal to the shortest
    /// possible header (Data and Disc tie at 20).
    public static let minimumPacketBytes: Int = HeaderLength.data

    /// Hard cap on a single packet's payload length, matching the
    /// 16-bit length field. Pure decoding sanity-check.
    public static let maximumPayloadBytes: Int = Int(UInt16.max)
}

/// Discriminator for [`BcUdpPacket`](../Wire/BcUdpPacket.swift)
/// variants. Decoded from the first four bytes of every BcUdp
/// packet on the wire.
public enum BcUdpPacketKind: UInt32, Sendable, CaseIterable {
    case disc = 0x2A87_CF3A
    case data = 0x2A87_CF10
    case ack  = 0x2A87_CF20

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

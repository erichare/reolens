import Foundation

/// Stream cipher for Reolink P2P discovery XML payloads.
///
/// The wire bytes inside a [`BcUdpDiscPacket.payload`](./BcUdpPacket.swift)
/// are XOR-obfuscated against a 32-byte key stream derived from a
/// hard-coded array of 8 × u32 constants and the Disc header's
/// `senderID`. The same routine encrypts and decrypts (XOR is
/// self-inverse) — `encrypt` and `decrypt` are aliases for clarity
/// at call sites.
///
/// ## Validation
///
/// Confirmed against the 2026-05-16 `p2p*.reolink.com` capture:
/// the first captured Disc query had `senderID = 0x003D0B9B` and
/// a 101-byte payload that decrypts cleanly to
/// `<P2P><C2M_Q><uid>…</uid><ver>3</ver><family>6</family>…`.
///
/// ## Provenance
///
/// Algorithm reverse-engineered by `thirtythreeforty/neolink`
/// (Rust, GPLv3 — `crates/core/src/bcudp/xml_crypto.rs`). The
/// key constants are facts about Reolink's protocol and not
/// copyrightable; the Swift implementation here is independent
/// and intentionally idiomatic for `Data` rather than a
/// line-by-line port.
public enum DiscoveryXMLCrypto {

    /// 32-byte key material expressed as 8 little-endian u32s.
    /// Stored as a `[UInt32]` to mirror Reolink's own conceptual
    /// layout (offset is added to each u32 before the LE byte
    /// expansion).
    static let keyWords: [UInt32] = [
        0x1F2D_3C4B,
        0x5A6C_7F8D,
        0x3817_2E4B,
        0x8271_635A,
        0x863F_1A2B,
        0xA5C6_F7D8,
        0x8371_E1B4,
        0x17F2_D3A5
    ]

    /// Apply the XOR cipher to `payload` with the given `offset`
    /// (typically `BcUdpDiscPacket.senderID` for requests; for
    /// replies the server echoes the client's `senderID` back in
    /// its own Disc header, so the caller threads the right
    /// value through). Same operation in both directions because
    /// XOR is symmetric.
    public static func transform(_ payload: Data, offset: UInt32) -> Data {
        guard !payload.isEmpty else { return payload }
        // Build the 32-byte key stream once.
        var stream = Data(capacity: 32)
        for word in keyWords {
            // Wrapping add per the Rust reference — overflow is
            // expected and not an error.
            let mixed = word &+ offset
            stream.append(UInt8(mixed & 0xFF))
            stream.append(UInt8((mixed >> 8) & 0xFF))
            stream.append(UInt8((mixed >> 16) & 0xFF))
            stream.append(UInt8((mixed >> 24) & 0xFF))
        }
        var out = Data(count: payload.count)
        out.withUnsafeMutableBytes { outPtr in
            payload.withUnsafeBytes { inPtr in
                stream.withUnsafeBytes { keyPtr in
                    let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress!
                    let inBase = inPtr.bindMemory(to: UInt8.self).baseAddress!
                    let keyBase = keyPtr.bindMemory(to: UInt8.self).baseAddress!
                    for i in 0..<payload.count {
                        outBase[i] = inBase[i] ^ keyBase[i % 32]
                    }
                }
            }
        }
        return out
    }

    /// Encrypt a plaintext XML payload for embedding into a
    /// `BcUdpDiscPacket`. The caller must use the same `offset`
    /// they'll put in the packet's `senderID` field.
    public static func encrypt(_ plaintext: Data, offset: UInt32) -> Data {
        transform(plaintext, offset: offset)
    }

    /// Decrypt the payload bytes from an incoming
    /// `BcUdpDiscPacket`. The `offset` is the `senderID` from
    /// the same packet's header — server replies echo the
    /// client's `senderID` value so a request/reply pair
    /// shares the keystream.
    public static func decrypt(_ ciphertext: Data, offset: UInt32) -> Data {
        transform(ciphertext, offset: offset)
    }
}

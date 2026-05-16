import Foundation

/// Internal little-endian `Data` helpers. Package-private so they
/// don't pollute the public surface.
///
/// The Reolink BcUdp wire format is little-endian throughout —
/// confirmed against a real `p2p*.reolink.com` capture: e.g. the
/// discovery magic appears on the wire as `3A CF 87 2A` and the
/// constant in [`BcUdpConstants.magicDisc`](./BcUdpConstants.swift)
/// is `0x2A87CF3A`, which round-trips only with LE serialization.
///
/// (Phase 1's first pass used big-endian helpers based on neolink
/// recall; the May 2026 wire capture corrected it. The companion
/// `ReolinkBaichuan` module also speaks little-endian — Reolink is
/// consistent across both protocols.)
extension Data {

    /// Append a 16-bit unsigned integer in little-endian order.
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// Append a 32-bit unsigned integer in little-endian order.
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Read a little-endian integer at a relative offset from
    /// `startIndex`. Returns nil if the slice doesn't have
    /// enough bytes (avoids the trap that `subscript` would
    /// raise — the codec uses `nil` to mean "need more bytes,
    /// keep buffering").
    func readLE<T: FixedWidthInteger & UnsignedInteger>(at offset: Int, as: T.Type) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard offset >= 0, offset + byteCount <= count else { return nil }
        var value: T = 0
        for i in (0..<byteCount).reversed() {
            let byte = self[startIndex + offset + i]
            value = (value << 8) | T(byte)
        }
        return value
    }

    /// Convenience for the common BcUdp dispatch: read the 32-bit
    /// magic at offset 0 and return it for kind-lookup. Returns
    /// nil on short buffer.
    func readLEMagic() -> UInt32? {
        readLE(at: 0, as: UInt32.self)
    }
}

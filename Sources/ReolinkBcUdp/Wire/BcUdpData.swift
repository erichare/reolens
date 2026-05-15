import Foundation

/// Internal big-endian `Data` helpers. Kept package-private (no
/// `public`) so they don't pollute the public surface — they
/// mirror `ReolinkBaichuan`'s little-endian `readLE`/`appendLE`
/// helpers but BcUdp is big-endian, so the two cannot share.
extension Data {

    /// Append a 16-bit unsigned integer in network byte order
    /// (big-endian).
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Append a 32-bit unsigned integer in network byte order
    /// (big-endian).
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Read a big-endian integer at a relative offset from
    /// `startIndex`. Returns nil if the slice doesn't have enough
    /// bytes (avoids the trap that `subscript` would raise on an
    /// out-of-bounds index — the codec uses `nil` to mean "need
    /// more bytes, keep buffering").
    func readBE<T: FixedWidthInteger & UnsignedInteger>(at offset: Int, as: T.Type) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard offset >= 0, offset + byteCount <= count else { return nil }
        var value: T = 0
        for i in 0..<byteCount {
            let byte = self[startIndex + offset + i]
            value = (value << 8) | T(byte)
        }
        return value
    }

    /// Convenience for the most common BcUdp use: read a 32-bit
    /// magic and return it for kind-dispatch. Returns nil on short
    /// buffer.
    func readBEMagic() -> UInt32? {
        readBE(at: 0, as: UInt32.self)
    }
}

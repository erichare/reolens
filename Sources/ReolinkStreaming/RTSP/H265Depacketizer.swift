import Foundation

/// Reassembles H.265/HEVC NAL units from RTP payloads per RFC 7798.
///
/// HEVC differs from H.264 here:
///   - The NAL unit header is **2 bytes** (not 1).
///   - Byte 0: `0 | NalType(6) | LayerId hi-bit`
///   - Byte 1: `LayerId(5 lo-bits) | TID(3)`
///   - Payload-header types of interest:
///     - 48: Aggregation Packet (AP) — multiple NALs back-to-back, length-prefixed (2 bytes each)
///     - 49: Fragmentation Unit (FU) — split one NAL across packets
///     - 0–47: single NAL unit
public struct H265Depacketizer: Sendable {

    public struct NALUnit: Sendable {
        public let bytes: Data        // 2-byte NAL header + payload, NO start code
        public let nalType: UInt8     // 0–47 in HEVC
        public let isKeyframe: Bool   // BLA/CRA/IDR (16–21)
    }

    private var fragmentBuffer = Data()
    private var inFragment = false

    public init() {}

    public mutating func depacketize(_ payload: Data) -> [NALUnit] {
        guard payload.count >= 2 else { return [] }
        let b0 = payload[payload.startIndex]
        let nalType = (b0 >> 1) & 0b0011_1111
        switch nalType {
        case 0...47:
            return [makeNAL(payload)]
        case 48:
            return parseAP(payload)
        case 49:
            return depacketizeFU(payload)
        default:
            return []
        }
    }

    private mutating func depacketizeFU(_ payload: Data) -> [NALUnit] {
        guard payload.count >= 3 else { return [] }
        let payloadHdrByte0 = payload[payload.startIndex]
        let payloadHdrByte1 = payload[payload.startIndex + 1]
        let fuHeader = payload[payload.startIndex + 2]
        let start = (fuHeader & 0b1000_0000) != 0
        let end = (fuHeader & 0b0100_0000) != 0
        let fuType = fuHeader & 0b0011_1111

        if start {
            // Rebuild the NAL header by replacing the type bits in PayloadHdr with fuType.
            let header0 = (payloadHdrByte0 & 0b1000_0001) | (fuType << 1)
            fragmentBuffer = Data([header0, payloadHdrByte1])
            fragmentBuffer.append(payload.subdata(in: (payload.startIndex + 3)..<payload.endIndex))
            inFragment = true
            return []
        }
        guard inFragment else { return [] }
        fragmentBuffer.append(payload.subdata(in: (payload.startIndex + 3)..<payload.endIndex))
        if end {
            let nal = makeNAL(fragmentBuffer)
            fragmentBuffer = Data()
            inFragment = false
            return [nal]
        }
        return []
    }

    private func parseAP(_ payload: Data) -> [NALUnit] {
        // AP: PayloadHdr (2 bytes), then [NALUSize (2 bytes) + NALU bytes]*
        var result: [NALUnit] = []
        var i = payload.startIndex + 2
        while i + 2 <= payload.endIndex {
            let size = Int(UInt16(payload[i]) << 8 | UInt16(payload[i + 1]))
            i += 2
            guard i + size <= payload.endIndex, size >= 2 else { break }
            let nalBytes = payload.subdata(in: i..<(i + size))
            result.append(makeNAL(nalBytes))
            i += size
        }
        return result
    }

    private func makeNAL(_ bytes: Data) -> NALUnit {
        guard bytes.count >= 1 else {
            return NALUnit(bytes: bytes, nalType: 0, isKeyframe: false)
        }
        let header = bytes[bytes.startIndex]
        let type = (header >> 1) & 0b0011_1111
        // HEVC keyframe NAL types: 16=BLA_W_LP, 17=BLA_W_RADL, 18=BLA_N_LP,
        // 19=IDR_W_RADL, 20=IDR_N_LP, 21=CRA_NUT.
        let isKey = (16...21).contains(type)
        return NALUnit(bytes: bytes, nalType: type, isKeyframe: isKey)
    }
}

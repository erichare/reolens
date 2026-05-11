import Foundation

/// Reassembles H.264 NAL units from RTP payloads per RFC 6184.
///
/// Reolink only uses single-NAL packets (types 1–23) and FU-A fragments (type 28).
/// We don't currently see STAP-A in the wild from these cameras, but we handle it
/// defensively.
public struct H264Depacketizer: Sendable {

    /// One reassembled access-unit-fragment (a single NAL unit, no start code).
    public struct NALUnit: Sendable {
        public let bytes: Data        // raw NAL bytes WITHOUT start code or AVCC length prefix
        public let nalType: UInt8     // bottom 5 bits of nal_unit_header
        public let isKeyframe: Bool   // type 5 = IDR
    }

    private var fragmentBuffer = Data()
    private var fragmentHeader: UInt8 = 0
    private var inFragment = false

    public init() {}

    public mutating func depacketize(_ payload: Data) -> [NALUnit] {
        guard let first = payload.first else { return [] }
        let nalType = first & 0b0001_1111
        switch nalType {
        case 1...23:
            // Single NAL unit packet.
            return [makeNAL(payload)]
        case 24:
            // STAP-A: aggregation packet — multiple NALs back-to-back, length-prefixed (2 bytes).
            return parseSTAPA(payload)
        case 28:
            // FU-A fragmentation.
            return depacketizeFUA(payload)
        default:
            // FU-B (29), MTAP (25/26/27), STAP-B (25) — uncommon for IP cameras.
            return []
        }
    }

    private mutating func depacketizeFUA(_ payload: Data) -> [NALUnit] {
        guard payload.count >= 2 else { return [] }
        let fuIndicator = payload[payload.startIndex]
        let fuHeader = payload[payload.startIndex + 1]
        let start = (fuHeader & 0b1000_0000) != 0
        let end = (fuHeader & 0b0100_0000) != 0
        let fragmentType = fuHeader & 0b0001_1111

        if start {
            // Reconstruct the original NAL header from FU indicator (top 3 bits) + FU header type bits.
            let reconstructedHeader = (fuIndicator & 0b1110_0000) | fragmentType
            fragmentBuffer = Data([reconstructedHeader])
            fragmentBuffer.append(payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex))
            fragmentHeader = reconstructedHeader
            inFragment = true
            return []
        }
        guard inFragment else { return [] }
        fragmentBuffer.append(payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex))
        if end {
            let nal = makeNAL(fragmentBuffer)
            fragmentBuffer = Data()
            inFragment = false
            return [nal]
        }
        return []
    }

    private func parseSTAPA(_ payload: Data) -> [NALUnit] {
        var result: [NALUnit] = []
        var i = payload.startIndex + 1 // skip the STAP-A NAL header byte
        while i + 2 <= payload.endIndex {
            let size = Int(UInt16(payload[i]) << 8 | UInt16(payload[i + 1]))
            i += 2
            guard i + size <= payload.endIndex, size > 0 else { break }
            let nalSlice = payload.subdata(in: i..<(i + size))
            result.append(makeNAL(nalSlice))
            i += size
        }
        return result
    }

    private func makeNAL(_ bytes: Data) -> NALUnit {
        let header = bytes.first ?? 0
        let type = header & 0b0001_1111
        return NALUnit(bytes: bytes, nalType: type, isKeyframe: type == 5)
    }
}

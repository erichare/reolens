import Foundation

/// RFC 3550 RTP packet — header (12 bytes) + optional CSRC + optional extension + payload.
///
/// We only parse what we need for video over Reolink: version, payload type, sequence
/// number, timestamp, marker bit, and the payload bytes.
public struct RTPPacket: Sendable {
    public let payloadType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let marker: Bool
    public let payload: Data

    public init?(raw: Data) {
        guard raw.count >= 12 else { return nil }
        let byte0 = raw[raw.startIndex]
        let byte1 = raw[raw.startIndex + 1]
        let version = (byte0 >> 6) & 0b11
        guard version == 2 else { return nil }
        let padding = (byte0 & 0b0010_0000) != 0
        let extensionPresent = (byte0 & 0b0001_0000) != 0
        let csrcCount = Int(byte0 & 0b0000_1111)
        self.marker = (byte1 & 0b1000_0000) != 0
        self.payloadType = byte1 & 0b0111_1111

        let seqOffset = raw.startIndex + 2
        self.sequenceNumber = UInt16(raw[seqOffset]) << 8 | UInt16(raw[seqOffset + 1])
        let tsOffset = raw.startIndex + 4
        self.timestamp = UInt32(raw[tsOffset]) << 24
            | UInt32(raw[tsOffset + 1]) << 16
            | UInt32(raw[tsOffset + 2]) << 8
            | UInt32(raw[tsOffset + 3])
        let ssrcOffset = raw.startIndex + 8
        self.ssrc = UInt32(raw[ssrcOffset]) << 24
            | UInt32(raw[ssrcOffset + 1]) << 16
            | UInt32(raw[ssrcOffset + 2]) << 8
            | UInt32(raw[ssrcOffset + 3])

        var payloadStart = raw.startIndex + 12 + (csrcCount * 4)
        if extensionPresent {
            guard raw.count >= payloadStart + 4 else { return nil }
            let extLen = Int(UInt16(raw[payloadStart + 2]) << 8 | UInt16(raw[payloadStart + 3]))
            payloadStart += 4 + (extLen * 4)
        }
        var payloadEnd = raw.endIndex
        if padding {
            guard payloadEnd > payloadStart else { return nil }
            let padLen = Int(raw[payloadEnd - 1])
            guard padLen <= payloadEnd - payloadStart else { return nil }
            payloadEnd -= padLen
        }
        guard payloadStart <= payloadEnd else { return nil }
        self.payload = raw.subdata(in: payloadStart..<payloadEnd)
    }
}

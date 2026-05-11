import Foundation

/// Binary header preceding every Baichuan message. Always little-endian.
///
/// Layout (20 or 24 bytes depending on class):
/// ```
///  0..3   magic              (u32 LE) = 0x0ABCDEF0 (or 0x0FEDCBA0 for some bin replies)
///  4..7   msg_id             (u32 LE)
///  8..11  body_len           (u32 LE)
/// 12      channel_id         (u8)  — for modern messages, low 4 bits double as XOR enc offset
/// 13      stream_type        (u8)
/// 14..15  msg_num            (u16 LE)
/// 16..17  response_code      (u16 LE) — modern only; legacy uses byte 16 for encrypt_xml flag
/// 18..19  class              (u16 LE)
/// 20..23  payload_offset     (u32 LE) — present only when header length is 24
/// ```
public struct BcHeader: Sendable, Hashable {
    public var msgID: UInt32
    public var bodyLength: UInt32
    public var channelID: UInt8
    public var streamType: UInt8
    public var msgNum: UInt16
    public var responseCode: UInt16
    public var msgClass: UInt16
    public var payloadOffset: UInt32?   // nil when class doesn't carry one

    public init(
        msgID: UInt32,
        bodyLength: UInt32,
        channelID: UInt8 = 0,
        streamType: UInt8 = 0,
        msgNum: UInt16,
        responseCode: UInt16 = 0,
        msgClass: UInt16,
        payloadOffset: UInt32? = nil
    ) {
        self.msgID = msgID
        self.bodyLength = bodyLength
        self.channelID = channelID
        self.streamType = streamType
        self.msgNum = msgNum
        self.responseCode = responseCode
        self.msgClass = msgClass
        self.payloadOffset = payloadOffset
    }

    public var headerLength: Int { BcConstants.headerLength(forClass: msgClass) }

    public func encode() -> Data {
        var bytes = Data(capacity: headerLength)
        bytes.appendLE(BcConstants.magicHeader)
        bytes.appendLE(msgID)
        bytes.appendLE(bodyLength)
        bytes.append(channelID)
        bytes.append(streamType)
        bytes.appendLE(msgNum)
        bytes.appendLE(responseCode)
        bytes.appendLE(msgClass)
        if BcConstants.hasPayloadOffset(msgClass) {
            bytes.appendLE(payloadOffset ?? 0)
        }
        return bytes
    }

    /// Parse a header from the start of `data`. Returns nil if there aren't
    /// enough bytes yet (caller should buffer and retry).
    public static func decode(from data: Data) -> BcHeader? {
        guard data.count >= 20 else { return nil }
        let magic = data.readLE(at: 0, as: UInt32.self)
        guard magic == BcConstants.magicHeader || magic == BcConstants.magicHeaderRev else {
            return nil
        }
        let msgID = data.readLE(at: 4, as: UInt32.self)
        let bodyLength = data.readLE(at: 8, as: UInt32.self)
        let channelID = data[data.startIndex + 12]
        let streamType = data[data.startIndex + 13]
        let msgNum = data.readLE(at: 14, as: UInt16.self)
        let responseCode = data.readLE(at: 16, as: UInt16.self)
        let msgClass = data.readLE(at: 18, as: UInt16.self)

        var payloadOffset: UInt32?
        if BcConstants.hasPayloadOffset(msgClass) {
            guard data.count >= 24 else { return nil }
            payloadOffset = data.readLE(at: 20, as: UInt32.self)
        }

        return BcHeader(
            msgID: msgID,
            bodyLength: bodyLength,
            channelID: channelID,
            streamType: streamType,
            msgNum: msgNum,
            responseCode: responseCode,
            msgClass: msgClass,
            payloadOffset: payloadOffset
        )
    }

    /// Sentinel high-byte for encryption negotiation in the legacy login reply.
    public static let encNegotiationHighByte: UInt8 = 0xDD

    /// Extract the negotiated encryption level from a login reply's
    /// `responseCode`. Returns nil if this isn't an encryption-negotiation
    /// reply.
    public var negotiatedEncryption: BcEncryptionLevel? {
        guard responseCode >> 8 == UInt16(Self.encNegotiationHighByte) else { return nil }
        return BcEncryptionLevel(rawValue: UInt8(responseCode & 0xFF))
    }
}

// MARK: - Data helpers

extension Data {
    /// Little-endian append.
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Read a little-endian integer at a relative offset.
    func readLE<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        var value: T = 0
        let byteCount = MemoryLayout<T>.size
        for i in 0..<byteCount {
            let byte = self[startIndex + offset + i]
            value |= T(byte) << (8 * i)
        }
        return value
    }
}

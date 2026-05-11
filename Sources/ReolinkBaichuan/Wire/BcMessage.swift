import Foundation

/// A complete Baichuan wire message: header + body bytes (already
/// encrypted/decrypted at the wire layer).
public struct BcMessage: Sendable {
    public var header: BcHeader
    public var body: Data

    public init(header: BcHeader, body: Data = Data()) {
        self.header = header
        self.body = body
    }

    /// Serialize using the given cipher. If `body` is XML and the message
    /// class supports a payload_offset, the entire body is encrypted as one
    /// chunk (no separate extension); we don't currently emit messages with
    /// the extension+payload split.
    public func encode(cipher: BcCipher) -> Data {
        // Reolink quirk (per Neolink's codex.rs): login messages (msg_id=1)
        // are always BCEncrypt-encoded on the outbound path even after AES has
        // been negotiated. The camera switches to AES only for subsequent
        // command/control messages.
        let effectiveCipher: BcCipher
        if header.msgID == BcMessageID.login, case .aes = cipher {
            effectiveCipher = .bcEncrypt
        } else {
            effectiveCipher = cipher
        }
        let encOffset = UInt32(header.channelID & 0x0F)
        let encryptedBody = effectiveCipher.encrypt(body, encOffset: encOffset)
        var out = header
        out.bodyLength = UInt32(encryptedBody.count)
        if BcConstants.hasPayloadOffset(out.msgClass) {
            out.payloadOffset = 0
        }
        return out.encode() + encryptedBody
    }

    /// Try to parse a complete message from the head of `buffer`. Returns the
    /// message and how many bytes were consumed, or nil if more data is needed.
    public static func decode(from buffer: Data, cipher: BcCipher) -> (BcMessage, consumed: Int)? {
        guard let header = BcHeader.decode(from: buffer) else { return nil }
        let totalLength = header.headerLength + Int(header.bodyLength)
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.startIndex + header.headerLength
        let bodyEnd = bodyStart + Int(header.bodyLength)
        let rawBody = buffer.subdata(in: bodyStart..<bodyEnd)
        // Decrypt the XML portion. For messages with a payload_offset, the
        // payload after the offset is binary (e.g., JPEG / H264) and not
        // encrypted; we leave that as-is. For simple XML messages, the body
        // is just the encrypted XML.
        let body: Data
        if BcConstants.hasPayloadOffset(header.msgClass), let po = header.payloadOffset, po > 0 {
            let extBytes = rawBody.prefix(Int(po))
            let binBytes = rawBody.dropFirst(Int(po))
            let decryptedExt = cipher.decrypt(Data(extBytes), encOffset: UInt32(header.channelID & 0x0F))
            body = decryptedExt + binBytes
        } else {
            body = cipher.decrypt(rawBody, encOffset: UInt32(header.channelID & 0x0F))
        }
        return (BcMessage(header: header, body: body), consumed: totalLength)
    }
}

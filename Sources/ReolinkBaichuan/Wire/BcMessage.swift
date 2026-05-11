import Foundation

/// A complete Baichuan wire message: header + optional channel-extension XML
/// + body bytes (encryption is applied at encode/decode time).
///
/// Modern messages on the hub (cmd_id ≥ ~100 with channel context, e.g.
/// `findAlarmVideo`) require a small `<Extension>` XML block carrying the
/// `<channelId>` *prepended* to the body. The extension and body are each
/// encrypted as independent AES streams and concatenated; the 24-byte header's
/// `payload_offset` field is set to the byte length of the encrypted extension
/// so the receiver knows where one ends and the other begins.
public struct BcMessage: Sendable {
    public var header: BcHeader
    public var body: Data
    /// Optional channel-extension XML inserted before the body. When non-nil,
    /// `encode` writes `AES(extensionBody) || AES(body)` and sets the header's
    /// `payload_offset` to the AES-encrypted extension length.
    public var extensionBody: Data?

    public init(header: BcHeader, body: Data = Data(), extensionBody: Data? = nil) {
        self.header = header
        self.body = body
        self.extensionBody = extensionBody
    }

    /// Serialize using the given cipher.
    ///
    /// - The extension and body are encrypted as separate AES streams (each
    ///   call to `cipher.encrypt` creates a fresh `CCCryptor`, so the IV
    ///   "0123456789abcdef" is re-applied to each chunk). This matches
    ///   `reolink_aio.baichuan._aes_encrypt(ext) + _aes_encrypt(body)`.
    /// - `payload_offset` is set to the encrypted extension length.
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
        let encryptedExt: Data
        if let ext = extensionBody, !ext.isEmpty {
            encryptedExt = effectiveCipher.encrypt(ext, encOffset: encOffset)
        } else {
            encryptedExt = Data()
        }
        let encryptedBody = effectiveCipher.encrypt(body, encOffset: encOffset)
        let payload = encryptedExt + encryptedBody

        var out = header
        out.bodyLength = UInt32(payload.count)
        if BcConstants.hasPayloadOffset(out.msgClass) {
            out.payloadOffset = UInt32(encryptedExt.count)
        }
        return out.encode() + payload
    }

    /// Try to parse a complete message from the head of `buffer`. Returns the
    /// message and how many bytes were consumed, or nil if more data is needed.
    ///
    /// When `payload_offset > 0`, the wire body is `AES(ext) || AES(body)`.
    /// Both chunks are XML and must be decrypted as independent AES streams.
    /// The decrypted extension is exposed on `extensionBody`; the decrypted
    /// body is on `body`. (If a future caller needs a binary post-offset
    /// payload — e.g. JPEG for `Snap` — it can read from `body` and decide
    /// whether to re-interpret the bytes.)
    public static func decode(from buffer: Data, cipher: BcCipher) -> (BcMessage, consumed: Int)? {
        guard let header = BcHeader.decode(from: buffer) else { return nil }
        let totalLength = header.headerLength + Int(header.bodyLength)
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.startIndex + header.headerLength
        let bodyEnd = bodyStart + Int(header.bodyLength)
        let rawBody = buffer.subdata(in: bodyStart..<bodyEnd)
        let encOffset = UInt32(header.channelID & 0x0F)

        let extensionBody: Data?
        let body: Data
        if BcConstants.hasPayloadOffset(header.msgClass), let po = header.payloadOffset, po > 0, Int(po) <= rawBody.count {
            let extEnd = rawBody.startIndex + Int(po)
            let extBytes = rawBody.subdata(in: rawBody.startIndex..<extEnd)
            let bodyBytes = rawBody.subdata(in: extEnd..<rawBody.endIndex)
            extensionBody = cipher.decrypt(extBytes, encOffset: encOffset)
            body = cipher.decrypt(bodyBytes, encOffset: encOffset)
        } else {
            extensionBody = nil
            body = cipher.decrypt(rawBody, encOffset: encOffset)
        }
        return (BcMessage(header: header, body: body, extensionBody: extensionBody), consumed: totalLength)
    }
}

import Foundation
import CryptoKit
import CommonCrypto

/// XOR-rotating key used by Reolink's `BCEncrypt` mode (older firmware).
private let xmlKey: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]

/// Fixed IV for AES-128-CFB Baichuan messages.
private let aesIV: [UInt8] = Array("0123456789abcdef".utf8)

/// Negotiated cipher used for XML bodies in Baichuan messages.
///
/// The Reolink camera advertises its supported levels in the login reply's
/// `response_code` (high byte `0xDD`, low byte = level). We pick the highest
/// level we support that the camera accepts.
public enum BcCipher: Sendable {
    case unencrypted
    case bcEncrypt
    case aes(key: Data)

    public func encrypt(_ payload: Data, encOffset: UInt32) -> Data {
        switch self {
        case .unencrypted: return payload
        case .bcEncrypt: return Self.xorRotate(payload, offset: encOffset)
        case .aes(let key): return Self.aesCFB(payload, key: key, encrypt: true) ?? payload
        }
    }

    public func decrypt(_ payload: Data, encOffset: UInt32) -> Data {
        switch self {
        case .unencrypted: return payload
        case .bcEncrypt: return Self.xorRotate(payload, offset: encOffset)
        case .aes(let key): return Self.aesCFB(payload, key: key, encrypt: false) ?? payload
        }
    }

    /// Reolink's XOR cipher — rotating 8-byte key XORed with `(offset & 0xff)`.
    private static func xorRotate(_ payload: Data, offset: UInt32) -> Data {
        let offsetByte = UInt8(offset & 0xFF)
        var output = Data(count: payload.count)
        for i in 0..<payload.count {
            let kIdx = (i + Int(offset)) % xmlKey.count
            output[i] = payload[payload.startIndex + i] ^ xmlKey[kIdx] ^ offsetByte
        }
        return output
    }

    /// AES-128-CFB128 via CommonCrypto's lower-level cryptor API. `CCCrypt`
    /// doesn't expose CFB; `CCCryptorCreateWithMode` does.
    private static func aesCFB(_ payload: Data, key: Data, encrypt: Bool) -> Data? {
        var cryptor: CCCryptorRef?
        let op = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            aesIV.withUnsafeBufferPointer { ivPtr in
                CCCryptorCreateWithMode(
                    op,
                    CCMode(kCCModeCFB),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count,
                    nil, 0, 0, 0,
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        let outLen = CCCryptorGetOutputLength(cryptor, payload.count, true)
        var output = Data(count: outLen)
        var produced = 0
        let updateStatus = output.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            payload.withUnsafeBytes { inPtr -> CCCryptorStatus in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress, payload.count,
                    outPtr.baseAddress, outLen,
                    &produced
                )
            }
        }
        guard updateStatus == kCCSuccess else { return nil }
        var finalProduced = 0
        let finalStatus = output.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            let basePtr = outPtr.baseAddress!.advanced(by: produced)
            return CCCryptorFinal(cryptor, basePtr, outLen - produced, &finalProduced)
        }
        guard finalStatus == kCCSuccess else { return nil }
        return output.prefix(produced + finalProduced)
    }
}

extension BcCipher {
    /// Build the AES key from the negotiated nonce + camera password using
    /// Reolink's recipe:
    ///
    ///   `key_phrase    = "{nonce}-{password}"`
    ///   `phrase_hash   = uppercase_hex(md5(key_phrase))`
    ///   `aes_key       = first 16 ASCII bytes of phrase_hash`
    ///
    /// Note: `aes_key` is the first 16 ASCII bytes of the hex *string*, not
    /// the first 16 raw bytes of the MD5 digest.
    public static func deriveAESKey(nonce: String, password: String) -> Data {
        let phrase = "\(nonce)-\(password)"
        let digest = Insecure.MD5.hash(data: Data(phrase.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return Data(hex.prefix(16).utf8)
    }
}

/// MD5 helpers matching Reolink's `md5_string` recipe:
/// uppercase hex of `md5(input)`, truncated to 31 chars (Truncate mode).
public enum BcMD5 {
    public static func reolinkHash(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(31))
    }
}

import Foundation

/// Protocol-level constants for the Baichuan/Reolink TCP port-9000 protocol.
///
/// Reference: `thirtythreeforty/neolink` (Rust), specifically `crates/core/src/bc/model.rs`.
public enum BcConstants {
    public static let defaultPort: UInt16 = 9000
    public static let magicHeader: UInt32 = 0x0ABC_DEF0
    public static let magicHeaderRev: UInt32 = 0x0FED_CBA0  // BE flavor seen on some binary replies

    // Header classes — determine the body shape AND the header length.
    public static let classLegacy: UInt16 = 0x6514                // 20-byte header, legacy body
    public static let classModern: UInt16 = 0x6614                // 20-byte header, modern XML body
    public static let classModernWithOffset: UInt16 = 0x6414      // 24-byte header
    public static let classModernFileDownload: UInt16 = 0x6482    // 24-byte header
    public static let classModernZero: UInt16 = 0x0000            // 24-byte header

    /// Header length per class.
    public static func headerLength(forClass cls: UInt16) -> Int {
        switch cls {
        case classLegacy, classModern: 20
        case classModernWithOffset, classModernFileDownload, classModernZero: 24
        default: 20
        }
    }

    /// `true` if this class includes the `payload_offset` field (24-byte header).
    public static func hasPayloadOffset(_ cls: UInt16) -> Bool {
        headerLength(forClass: cls) == 24
    }
}

/// Message IDs from `neolink/crates/core/src/bc/model.rs` — the most important
/// ones we may want to use. Many more exist; add as needed.
public enum BcMessageID {
    public static let login: UInt32 = 1
    public static let logout: UInt32 = 2
    public static let video: UInt32 = 3
    public static let videoStop: UInt32 = 4
    public static let talkAbility: UInt32 = 10
    public static let talkReset: UInt32 = 11
    public static let ptzControl: UInt32 = 18
    public static let reboot: UInt32 = 23
    public static let motionRequest: UInt32 = 31   // ask camera to send motion events
    public static let motion: UInt32 = 33          // server-initiated AlarmEventList
    public static let version: UInt32 = 80
    public static let ping: UInt32 = 93
    public static let snap: UInt32 = 109
    public static let uid: UInt32 = 114
    public static let pushInfo: UInt32 = 124
    public static let abilityInfo: UInt32 = 151
    public static let support: UInt32 = 199
    public static let talkConfig: UInt32 = 201
    public static let talk: UInt32 = 202
    public static let batteryInfoList: UInt32 = 252
    public static let batteryInfo: UInt32 = 253
    public static let findAlarmVideo: UInt32 = 272 // search historical alarm-triggered video
    public static let alarmVideoInfo: UInt32 = 273
}

/// Encryption protocol negotiated during login. Returned by the server in the
/// low byte of the legacy login response_code (high byte is `0xDD`).
public enum BcEncryptionLevel: UInt8, Sendable {
    case unencrypted = 0x00
    case bcEncrypt = 0x01
    case aes = 0x02
    case fullAes = 0x12

    /// The byte the client sends in the legacy login `response_code` to
    /// request a given maximum encryption level (high byte = `0xDC`).
    public var requestByte: UInt16 {
        UInt16(0xDC00) | UInt16(rawValue)
    }
}

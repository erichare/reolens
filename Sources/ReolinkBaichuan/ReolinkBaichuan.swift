import Foundation

/// Swift port of Reolink's proprietary "Baichuan" protocol over TCP port 9000.
///
/// This protocol is undocumented; the implementation is ported from
/// `thirtythreeforty/neolink` (Rust) and validated against its Wireshark
/// dissector. See `Wire/BcHeader.swift`, `Wire/Encryption.swift`,
/// `BaichuanClient.swift`, `BaichuanLogin.swift`, `BaichuanEvents.swift`.
///
/// Phase 1 (this build):
///   - TCP framing with magic 0x0ABCDEF0 little-endian
///   - BCEncrypt (XOR-rotating) and AES-128-CFB cipher modes
///   - Legacy login upgrade → modern login with MD5'd nonce credentials
///   - Server-push event subscription (msg_id=31 request, msg_id=33 deliver)
///   - Motion + AI event parsing from `<AlarmEventList>` payloads
///
/// Phase 2 (future):
///   - msg_id=272/273 findAlarmVideo — historical event tags for recordings
///   - msg_id=252/253 battery wake_op for sleeping cameras
///   - msg_id=201/202 talkback — capture mic + ADPCM encode + send
public enum ReolinkBaichuan {
    public static let version = "0.1.0"
    public static let defaultPort: UInt16 = BcConstants.defaultPort
}

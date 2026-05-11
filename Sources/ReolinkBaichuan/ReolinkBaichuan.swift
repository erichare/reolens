import Foundation

/// Stub module for Reolink's proprietary "Baichuan" protocol over TCP port 9000.
///
/// This is the protocol Reolink's own apps use for:
///   - Two-way audio / talkback (the only way — RTSP doesn't carry uplink audio).
///   - TCP push notifications for motion / AI events (lower-latency than the
///     CGI polling we currently do).
///   - Waking sleeping battery cameras (Argus, Go, Doorbell battery models).
///
/// It is a binary XML-over-custom-header protocol with handshake, optional AES
/// encryption (newer firmware), and per-message-type framing. The handshake
/// alone is multi-step (Mod-D, Mod-K, c1/c2 key exchange). A complete
/// implementation is several thousand lines of code and requires careful
/// reverse-engineering against a working reference.
///
/// **Recommended reference implementations to port from:**
///   - Rust: [`thirtythreeforty/neolink`](https://github.com/thirtythreeforty/neolink) —
///     the de-facto standard, with a Wireshark dissector in
///     `neolink/dissector/baichuan.lua`.
///   - Python: [`starkillerOG/reolink_aio`](https://github.com/starkillerOG/reolink_aio) —
///     covers the talkback + TCP push subset used by Home Assistant.
///
/// **Implementation phases** (rough order):
///   1. TCP connection + Mod-D handshake (login)
///   2. Encrypted login (Mod-K, AES) for newer firmware
///   3. TCP push subscription → bridge events to `CameraSession.motionState` etc.
///   4. Battery wake_op for sleeping cameras
///   5. Talkback: capture mic via `AVAudioEngine` → resample 16 kHz mono →
///      ADPCM encode → wrap in Baichuan `talk` frames → send.
///
/// For now this module exposes only the version constant so the package builds.
public enum ReolinkBaichuan {
    public static let version = "0.0.1-stub"
    public static let defaultPort: UInt16 = 9000
}

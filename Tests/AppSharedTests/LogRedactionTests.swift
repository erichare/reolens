import Testing
import Foundation
@testable import ReolinkAPI

/// AGENTS.md §11 — every URL going through unified logging must
/// have credentials stripped. `LogRedaction.redact(_:)` is the
/// single helper everyone uses; these tests pin its contract so a
/// regression here surfaces immediately.
@Suite("LogRedaction")
struct LogRedactionTests {

    @Test("Drops embedded userInfo from RTSP URLs")
    func dropsUserInfoFromRTSP() {
        let raw = "rtsp://admin:s3cret@192.168.1.42:554/h264Preview_01_main"
        let redacted = LogRedaction.redact(raw)
        #expect(!redacted.contains("admin"))
        #expect(!redacted.contains("s3cret"))
        // Host + path still present so logs are useful.
        #expect(redacted.contains("192.168.1.42"))
        #expect(redacted.contains("h264Preview_01_main"))
    }

    @Test("Elides token query parameter")
    func elidesTokenQuery() {
        let url = URL(string: "https://192.168.1.42/cgi-bin/api.cgi?cmd=Snap&channel=0&token=abc123xyz")!
        let redacted = LogRedaction.redact(url)
        #expect(!redacted.contains("abc123xyz"))
        // Key stays, value is replaced with the REDACTED placeholder
        // (ASCII so it survives URL-encoding inside URLComponents).
        #expect(redacted.contains("token=REDACTED"))
        // Non-sensitive params survive.
        #expect(redacted.contains("cmd=Snap"))
        #expect(redacted.contains("channel=0"))
    }

    @Test("Elides user/password query parameters")
    func elidesUserAndPassword() {
        let url = URL(string: "https://192.168.1.42/cgi-bin/api.cgi?cmd=Download&source=clip.mp4&user=admin&password=s3cret")!
        let redacted = LogRedaction.redact(url)
        #expect(!redacted.contains("admin"))
        #expect(!redacted.contains("s3cret"))
        #expect(redacted.contains("cmd=Download"))
        #expect(redacted.contains("source=clip.mp4"))
    }

    @Test("Nil URL surfaces a stable sentinel")
    func nilUrlSentinel() {
        #expect(LogRedaction.redact(nil as URL?) == "<no-url>")
    }

    @Test("Truly-unparseable string scrubs userInfo segment regex-style")
    func unparseableScrubbedRegex() {
        // String with embedded spaces that URL(string:) rejects.
        // Falls through to the regex fallback in `redact(_:)`.
        let raw = "fragment with spaces //user:secret@host:1234/path"
        let redacted = LogRedaction.redact(raw)
        // The regex strips the `//user:secret@` segment between
        // scheme-like prefix and host. Either it parses (no
        // userInfo) or the regex strips it.
        #expect(!redacted.contains("user:secret"))
    }

    @Test("Case-insensitive sensitive-query match")
    func caseInsensitive() {
        let url = URL(string: "https://192.168.1.42/cgi-bin/api.cgi?Token=ABCDEF")!
        let redacted = LogRedaction.redact(url)
        #expect(!redacted.contains("ABCDEF"))
    }
}

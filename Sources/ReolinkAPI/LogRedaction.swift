import Foundation

/// Helpers for emitting log lines that touch Reolink URLs without
/// leaking credentials. AGENTS.md §11 — passwords, tokens, full
/// auth-bearing URLs must never reach unified logging at any level.
///
/// Use these instead of `url.absoluteString` whenever a URL is going
/// to be interpolated into an `os.Logger` call or surfaced in
/// user-visible error text.
public enum LogRedaction {

    /// Sanitize a URL for logging: drops userInfo, drops sensitive
    /// query items (`token`, `user`, `password`), and keeps the
    /// scheme + host + port + path so logs are still useful for
    /// diagnosis. Produces strings like:
    ///
    ///     rtsp://<host>:554/h264Preview_01_main
    ///     https://<host>/cgi-bin/api.cgi?cmd=Snap&channel=0&token=…
    ///
    /// The host is preserved (it's a LAN IP / RFC1918 address in
    /// practice) but never the embedded credentials.
    public static func redact(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<no-url>"
        }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.map { item in
            if Self.sensitiveQueryKeys.contains(item.name.lowercased()) {
                // Use ASCII so the placeholder survives `components.string`
                // URL-encoding without getting re-escaped — and remains
                // greppable in unified logging.
                return URLQueryItem(name: item.name, value: "REDACTED")
            }
            return item
        }
        // Defense in depth: some malformed-but-URL-decodable inputs
        // can carry an embedded `//user:password@host` segment that
        // URLComponents doesn't recognize as userInfo (because it's
        // not in scheme position). Strip those regex-style as a
        // final pass before returning.
        return stripEmbeddedUserInfo(components.string ?? "<unprintable-url>")
    }

    /// Variant for callers that have an `absoluteString` already and
    /// want to redact it for log emission. Falls through to
    /// `redact(URL?)` when parseable, otherwise scrubs the substring
    /// regex-style as a last resort.
    public static func redact(_ urlString: String) -> String {
        if let url = URL(string: urlString) {
            return redact(url)
        }
        // URL parser rejected the string outright — fall through to
        // the same regex-based scrub `redact(URL?)` uses as defense
        // in depth.
        return stripEmbeddedUserInfo(urlString)
    }

    /// Regex strip of any `//user:password@` segment between a
    /// scheme-like prefix and a host. Conservative — only matches
    /// the canonical RFC-3986 userInfo position.
    private static func stripEmbeddedUserInfo(_ s: String) -> String {
        var scrubbed = s
        // Iterate so multiple userInfo-like segments all get
        // stripped, not just the first.
        while let range = scrubbed.range(of: "//[^/\\s]*@", options: .regularExpression) {
            scrubbed.replaceSubrange(range, with: "//")
        }
        return scrubbed
    }

    /// Query parameter names whose values must be redacted. Keep the
    /// key visible so log readers can see *that* a token was present;
    /// drop the value.
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "user", "password", "p", "secret"
    ]
}

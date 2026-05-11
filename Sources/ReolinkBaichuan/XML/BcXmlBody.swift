import Foundation

/// Build and parse the minimal Baichuan XML payloads we need for login + AI
/// events. The protocol's XML schema is variable across firmware, so rather
/// than codify a full Codable surface, we build/parse the specific shapes by
/// name lookup.
public enum BcXmlBody {

    /// Build `<?xml ?> <body><LoginUser>...</LoginUser><LoginNet>...</LoginNet></body>`
    /// payload sent in the modern-login phase.
    public static func loginUserAndNet(usernameHash: String, passwordHash: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <LoginUser version="1.1">
        <userName>\(usernameHash)</userName>
        <password>\(passwordHash)</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="1.1">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>
        </body>
        """
        return Data(xml.utf8)
    }

    /// Find the first `<nonce>...</nonce>` value in the given XML body.
    public static func extractNonce(from xml: Data) -> String? {
        guard let text = String(data: xml, encoding: .utf8) else { return nil }
        return firstTagContent(in: text, tag: "nonce")
    }

    /// Extract a child tag's text content (first occurrence).
    public static func firstTagContent(in xml: String, tag: String) -> String? {
        // Naive but sufficient for the flat XML the camera emits.
        guard let openRange = xml.range(of: "<\(tag)>") else { return nil }
        guard let closeRange = xml.range(of: "</\(tag)>", range: openRange.upperBound..<xml.endIndex) else { return nil }
        return String(xml[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation
import ReolinkAPI

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
        guard let openRange = xml.range(of: "<\(tag)>") else { return nil }
        guard let closeRange = xml.range(of: "</\(tag)>", range: openRange.upperBound..<xml.endIndex) else { return nil }
        return String(xml[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return the inner text of EVERY occurrence of `<tag>...</tag>` (or
    /// `<tag attrs>...</tag>`) in the XML. Used for iterating sibling
    /// elements like `<alarmVideo>` blocks inside `<alarmVideoList>`.
    public static func allBlocks(in xml: String, tag: String) -> [String] {
        var results: [String] = []
        var searchStart = xml.startIndex
        let openPattern = "<\(tag)"
        let closePattern = "</\(tag)>"
        while searchStart < xml.endIndex {
            guard let openTagStart = xml.range(of: openPattern, range: searchStart..<xml.endIndex) else { break }
            // Find the end of the opening tag's `>`
            guard let openTagEnd = xml.range(of: ">", range: openTagStart.upperBound..<xml.endIndex) else { break }
            guard let closeTagStart = xml.range(of: closePattern, range: openTagEnd.upperBound..<xml.endIndex) else { break }
            let inner = String(xml[openTagEnd.upperBound..<closeTagStart.lowerBound])
            results.append(inner)
            searchStart = closeTagStart.upperBound
        }
        return results
    }

    /// Parse a Reolink time element `<startTime><year>...</year><month>...</month>...</startTime>`
    /// from the given inner XML.
    public static func reolinkTime(in xml: String, tag: String) -> ReolinkTime? {
        guard let block = allBlocks(in: xml, tag: tag).first else { return nil }
        guard let year = firstTagContent(in: block, tag: "year").flatMap(Int.init),
              let mon = firstTagContent(in: block, tag: "month").flatMap(Int.init)
                ?? firstTagContent(in: block, tag: "mon").flatMap(Int.init),
              let day = firstTagContent(in: block, tag: "day").flatMap(Int.init) else {
            return nil
        }
        let hour = firstTagContent(in: block, tag: "hour").flatMap(Int.init) ?? 0
        let minute = firstTagContent(in: block, tag: "minute").flatMap(Int.init)
            ?? firstTagContent(in: block, tag: "min").flatMap(Int.init)
            ?? 0
        let second = firstTagContent(in: block, tag: "second").flatMap(Int.init)
            ?? firstTagContent(in: block, tag: "sec").flatMap(Int.init)
            ?? 0
        return ReolinkTime(year: year, mon: mon, day: day, hour: hour, min: minute, sec: second)
    }
}

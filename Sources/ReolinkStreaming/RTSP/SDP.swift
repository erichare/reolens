import Foundation

/// Minimal SDP parser geared for what Reolink cameras return in DESCRIBE responses.
/// We only need to find the video track, its payload type, codec, and the
/// `sprop-parameter-sets` (H.264) / `sprop-vps`/`sprop-sps`/`sprop-pps` (HEVC) values.
public struct SessionDescription: Sendable, Hashable {
    public var media: [MediaDescription] = []

    public var firstVideoTrack: MediaDescription? {
        media.first(where: { $0.kind == "video" })
    }
}

public struct MediaDescription: Sendable, Hashable {
    public var kind: String
    public var port: Int
    public var protocolName: String
    public var formats: [Int]
    public var control: String?
    public var rtpmap: Rtpmap?
    public var fmtp: [String: String] = [:]
}

public struct Rtpmap: Sendable, Hashable {
    public var payloadType: Int
    public var codec: String
    public var clockRate: Int
}

public enum SDPParser {

    public static func parse(_ text: String) -> SessionDescription {
        var session = SessionDescription()
        var current: MediaDescription?

        // 1. Strip a UTF-8 BOM if present.
        var input = text
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }

        // 2. Normalize all line endings to \n. RTSP wire format uses \r\n; we want
        //    to feed the line-by-line scanner a clean stream and not have to worry
        //    about CR sneaking into trailing characters of substrings.
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            // Convert to String and strip any control bytes (NUL padding etc.).
            let line = String(rawLine).trimmingCharacters(in: stripSet)
            guard line.count >= 2 else { continue }
            // SDP lines are "<key>=<value>" where key is one letter.
            let keyEnd = line.index(after: line.startIndex)
            guard line[keyEnd] == "=" else { continue }
            let key = String(line[..<keyEnd])
            let value = String(line[line.index(after: keyEnd)...])

            switch key {
            case "m":
                if let cur = current { session.media.append(cur) }
                current = parseMediaLine(value)
            case "a":
                if current != nil {
                    applyAttribute(value, to: &current!)
                }
            default:
                break
            }
        }
        if let cur = current { session.media.append(cur) }
        return session
    }

    /// Everything we want to strip from a line: whitespace, newlines, NUL.
    private static let stripSet: CharacterSet = {
        var s = CharacterSet.whitespacesAndNewlines
        s.insert(charactersIn: "\u{00}")
        return s
    }()

    private static func parseMediaLine(_ value: String) -> MediaDescription {
        // `m=video 0 RTP/AVP 96`
        let parts = value.split(separator: " ").map(String.init)
        let kind = parts.first ?? ""
        let port = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let proto = parts.count > 2 ? parts[2] : ""
        let formats = parts.dropFirst(3).compactMap(Int.init)
        return MediaDescription(kind: kind, port: port, protocolName: proto, formats: formats)
    }

    private static func applyAttribute(_ value: String, to media: inout MediaDescription) {
        guard let colon = value.firstIndex(of: ":") else {
            // Flag-style attribute (no colon)
            return
        }
        let name = String(value[..<colon])
        let body = String(value[value.index(after: colon)...])

        switch name {
        case "control":
            media.control = body
        case "rtpmap":
            // `96 H264/90000` or `96 H264/90000/1`
            let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pt = Int(parts[0]) else { return }
            let codecAndRate = parts[1].split(separator: "/").map(String.init)
            guard codecAndRate.count >= 2, let rate = Int(codecAndRate[1]) else { return }
            media.rtpmap = Rtpmap(payloadType: pt, codec: codecAndRate[0], clockRate: rate)
        case "fmtp":
            // `96 packetization-mode=1;profile-level-id=4D0029;sprop-parameter-sets=Z00AKZ2oFAFuQA==,aO48gA==`
            guard let space = body.firstIndex(of: " ") else { return }
            let params = String(body[body.index(after: space)...])
            for kv in params.split(separator: ";") {
                let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    media.fmtp[pair[0].trimmingCharacters(in: .whitespaces)] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                } else if pair.count == 1 {
                    media.fmtp[pair[0].trimmingCharacters(in: .whitespaces)] = ""
                }
            }
        default:
            break
        }
    }
}

public extension MediaDescription {
    /// For H.264, returns `(sps, pps)` extracted from `sprop-parameter-sets`.
    var h264ParameterSets: (sps: Data, pps: Data)? {
        guard let v = fmtp["sprop-parameter-sets"] else { return nil }
        let parts = v.split(separator: ",").map(String.init)
        guard parts.count >= 2,
              let sps = Data(base64Encoded: parts[0]),
              let pps = Data(base64Encoded: parts[1]) else { return nil }
        return (sps, pps)
    }

    /// For HEVC/H.265, returns `(vps, sps, pps)`.
    var h265ParameterSets: (vps: Data, sps: Data, pps: Data)? {
        guard let vpsStr = fmtp["sprop-vps"],
              let spsStr = fmtp["sprop-sps"],
              let ppsStr = fmtp["sprop-pps"],
              let vps = Data(base64Encoded: vpsStr),
              let sps = Data(base64Encoded: spsStr),
              let pps = Data(base64Encoded: ppsStr) else { return nil }
        return (vps, sps, pps)
    }
}

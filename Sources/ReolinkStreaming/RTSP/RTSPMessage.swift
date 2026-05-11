import Foundation

public struct RTSPResponse: Sendable {
    public let statusCode: Int
    public let reason: String
    public let headers: [String: String]
    public let body: String

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == lower })?.value
    }
}

public enum RTSPMessageParser {

    /// Try to parse one complete RTSP response from `buffer`. Returns the response
    /// plus the number of bytes consumed (suitable for `removeFirst(consumed)`),
    /// or `nil` if more data is needed.
    ///
    /// Implementation note: `Data` retains its underlying offset across mutating
    /// operations (after `removeFirst`, `startIndex` is non-zero). All internal
    /// math uses absolute indices, but the returned `consumed` is in count-units.
    public static func parse(_ buffer: Data) -> (RTSPResponse, consumed: Int)? {
        guard let headersEnd = findCRLFCRLF(in: buffer) else { return nil }

        guard let headersText = String(
            data: buffer.subdata(in: buffer.startIndex..<headersEnd),
            encoding: .ascii
        ) else { return nil }

        let lines = headersText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else { return nil }
        let reason = statusParts.count >= 3 ? statusParts[2] : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headersEnd + 4   // absolute index
        var bodyEnd = bodyStart           // absolute index

        if let lenStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let len = Int(lenStr), len > 0 {
            guard buffer.endIndex >= bodyStart + len else { return nil }
            bodyEnd = bodyStart + len
            let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            let response = RTSPResponse(statusCode: code, reason: reason, headers: headers, body: body)
            return (response, consumed: bodyEnd - buffer.startIndex)
        }

        let response = RTSPResponse(statusCode: code, reason: reason, headers: headers, body: "")
        return (response, consumed: bodyEnd - buffer.startIndex)
    }

    /// Returns the absolute index of the first CRLFCRLF, or nil.
    private static func findCRLFCRLF(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var i = data.startIndex
        let end = data.endIndex - 4
        while i <= end {
            if data[i] == 0x0D &&
                data[i + 1] == 0x0A &&
                data[i + 2] == 0x0D &&
                data[i + 3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }
}

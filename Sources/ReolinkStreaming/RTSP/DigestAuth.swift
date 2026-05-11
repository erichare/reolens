import Foundation
import CryptoKit

/// HTTP Digest authentication challenge parsing + response computation.
/// Reolink RTSP servers use Digest auth by default; Basic is opt-in via web UI.
public struct DigestChallenge: Sendable {
    public let realm: String
    public let nonce: String
    public let qop: String?
    public let algorithm: String?
    public let opaque: String?

    public init?(headerValue: String) {
        // `Digest realm="...", nonce="...", qop="auth", algorithm=MD5`
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest ") else { return nil }
        let body = String(trimmed.dropFirst(7))

        var params: [String: String] = [:]
        var i = body.startIndex
        while i < body.endIndex {
            // Skip whitespace/comma.
            while i < body.endIndex, body[i] == " " || body[i] == "," { i = body.index(after: i) }
            guard let eq = body[i...].firstIndex(of: "=") else { break }
            let key = String(body[i..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            i = body.index(after: eq)
            var value: String
            if i < body.endIndex, body[i] == "\"" {
                let start = body.index(after: i)
                guard let endQuote = body[start...].firstIndex(of: "\"") else { break }
                value = String(body[start..<endQuote])
                i = body.index(after: endQuote)
            } else {
                let end = body[i...].firstIndex(where: { $0 == "," }) ?? body.endIndex
                value = String(body[i..<end]).trimmingCharacters(in: .whitespaces)
                i = end
            }
            params[key] = value
        }
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        self.realm = realm
        self.nonce = nonce
        self.qop = params["qop"]
        self.algorithm = params["algorithm"]
        self.opaque = params["opaque"]
    }
}

public enum DigestAuth {

    public static func response(
        username: String,
        password: String,
        method: String,
        uri: String,
        challenge: DigestChallenge,
        cnonce: String? = nil,
        nc: String = "00000001"
    ) -> String {
        let cnonce = cnonce ?? randomCnonce()
        let ha1 = md5("\(username):\(challenge.realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let qop = challenge.qop?.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        let response: String
        if let qop, qop == "auth" {
            response = md5("\(ha1):\(challenge.nonce):\(nc):\(cnonce):auth:\(ha2)")
        } else {
            response = md5("\(ha1):\(challenge.nonce):\(ha2)")
        }

        var parts = [
            "username=\"\(username)\"",
            "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\""
        ]
        if let algo = challenge.algorithm { parts.append("algorithm=\(algo)") }
        if let qop, qop == "auth" {
            parts.append("qop=auth")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        if let opaque = challenge.opaque {
            parts.append("opaque=\"\(opaque)\"")
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    public static func basicResponse(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }

    private static func md5(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func makeCnonce() -> String { randomCnonce() }

    private static func randomCnonce() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

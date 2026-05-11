import Foundation

public struct CameraCredentials: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let useHTTPS: Bool

    public init(host: String, port: Int = 80, username: String, password: String, useHTTPS: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS
    }

    public var baseURL: URL {
        let scheme = useHTTPS ? "https" : "http"
        let portSuffix = (useHTTPS && port == 443) || (!useHTTPS && port == 80) ? "" : ":\(port)"
        return URL(string: "\(scheme)://\(host)\(portSuffix)")!
    }

    public var cgiURL: URL {
        baseURL.appendingPathComponent("cgi-bin/api.cgi")
    }
}

public struct Token: Sendable, Hashable, Codable {
    public let name: String
    public let issuedAt: Date
    public let leaseTime: TimeInterval

    public var expiresAt: Date { issuedAt.addingTimeInterval(leaseTime) }

    public func isExpiring(within slack: TimeInterval = 60) -> Bool {
        Date().addingTimeInterval(slack) >= expiresAt
    }
}

public enum StreamKind: String, Sendable, CaseIterable, Codable {
    case main, sub, ext
}

public enum VideoCodec: String, Sendable, Codable {
    case h264, h265
}

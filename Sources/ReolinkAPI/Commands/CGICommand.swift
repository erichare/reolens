import Foundation

public enum CGIAction: Int, Sendable, Codable {
    case get = 0
    case getDetailed = 1
}

public struct CGICommand<Param: Encodable & Sendable>: Encodable, Sendable {
    public let cmd: String
    public let action: CGIAction
    public let param: Param

    public init(cmd: String, action: CGIAction = .get, param: Param) {
        self.cmd = cmd
        self.action = action
        self.param = param
    }
}

public struct EmptyParam: Codable, Sendable {
    public init() {}
}

public struct ChannelParam: Codable, Sendable {
    public let channel: Int
    public init(channel: Int = 0) { self.channel = channel }
}

public struct CGIResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    public let cmd: String
    public let code: Int
    public let value: Value?
    public let error: CGIError?

    public var isSuccess: Bool { code == 0 }
}

public struct CGIError: Decodable, Sendable, Error, CustomStringConvertible {
    public let rspCode: Int
    public let detail: String?

    public var description: String {
        let known = CGIErrorCode(rawValue: rspCode)?.description ?? "Unknown error"
        return "Reolink error \(rspCode): \(known)\(detail.map { " — \($0)" } ?? "")"
    }
}

public enum CGIErrorCode: Int, Sendable {
    case missingParam = -1
    case usedUp = -2
    case createSocketError = -3
    case sendError = -4
    case protocolError = -5
    case readError = -6
    case openFileError = -7
    case operationFailed = -8
    case notSupport = -9
    case loginRequired = -10
    case loginError = -11
    case operationTimeout = -12
    case noTokens = -13
    case invalidUser = -14
    case loginAlready = -15
    case lockedByOthers = -16
    case noAuthority = -17
    case dataReadyTimeOut = -18
    case unsupportedProtocol = -19
    case loginFailed = -20

    public var description: String {
        switch self {
        case .missingParam: return "Missing parameters"
        case .usedUp: return "Resources used up"
        case .createSocketError: return "Socket error"
        case .sendError: return "Send error"
        case .protocolError: return "Protocol error"
        case .readError: return "Read error"
        case .openFileError: return "Open file error"
        case .operationFailed: return "Operation failed"
        case .notSupport: return "Not supported"
        case .loginRequired: return "Login required"
        case .loginError: return "Login error"
        case .operationTimeout: return "Operation timeout"
        case .noTokens: return "No tokens available"
        case .invalidUser: return "Invalid user"
        case .loginAlready: return "Already logged in"
        case .lockedByOthers: return "Locked by another session"
        case .noAuthority: return "No authority"
        case .dataReadyTimeOut: return "Data ready timeout"
        case .unsupportedProtocol: return "Unsupported protocol"
        case .loginFailed: return "Login failed"
        }
    }
}

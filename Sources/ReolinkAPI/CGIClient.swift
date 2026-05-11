import Foundation

public enum ReolinkClientError: Error, CustomStringConvertible {
    case transport(any Error)
    case malformedResponse(String)
    case http(status: Int, body: String?)
    case loginFailed(CGIError?)
    case notLoggedIn
    case commandFailed(cmd: String, error: CGIError)
    case emptyResponse

    public var description: String {
        switch self {
        case .transport(let e): return "Transport error: \(e)"
        case .malformedResponse(let s): return "Malformed response: \(s)"
        case .http(let status, let body): return "HTTP \(status): \(body ?? "<no body>")"
        case .loginFailed(let e): return "Login failed: \(e?.description ?? "unknown")"
        case .notLoggedIn: return "Not logged in"
        case .commandFailed(let cmd, let e): return "Command \(cmd) failed: \(e.description)"
        case .emptyResponse: return "Empty response"
        }
    }
}

/// An actor-isolated client for one Reolink device (camera or NVR).
/// Manages a single token lease and serializes login/refresh to avoid the device's
/// notoriously tight session caps.
public actor CGIClient {

    public let credentials: CameraCredentials
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var token: Token?
    private var loginTask: Task<Token, any Error>?

    public init(
        credentials: CameraCredentials,
        urlSession: URLSession? = nil
    ) {
        self.credentials = credentials
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            config.httpMaximumConnectionsPerHost = 4
            // Reolink devices commonly use self-signed certs over HTTPS.
            self.urlSession = URLSession(configuration: config, delegate: PermissiveTLSDelegate(), delegateQueue: nil)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = []
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    public var currentToken: Token? { token }

    public func login() async throws -> Token {
        if let token, !token.isExpiring() {
            return token
        }
        if let existing = loginTask {
            return try await existing.value
        }
        let task = Task<Token, any Error> { [credentials] in
            let cmd = Commands.login(username: credentials.username, password: credentials.password)
            let raw = try await self.postRaw(commands: [AnyEncodable(cmd)], token: nil)
            let responses = try self.decodeAny(raw, as: LoginResult.self)
            guard let first = responses.first else { throw ReolinkClientError.emptyResponse }
            if let err = first.error { throw ReolinkClientError.loginFailed(err) }
            guard let value = first.value else { throw ReolinkClientError.loginFailed(nil) }
            let issued = Date()
            let token = Token(name: value.Token.name, issuedAt: issued, leaseTime: TimeInterval(value.Token.leaseTime))
            return token
        }
        loginTask = task
        defer { loginTask = nil }
        let t = try await task.value
        self.token = t
        return t
    }

    public func logout() async {
        guard token != nil else { return }
        do {
            _ = try await self.send(Commands.logout(), as: EmptyResult.self)
        } catch {
            // ignore — best effort
        }
        token = nil
    }

    /// Send a single command, decoding the value as `T`.
    public func send<P: Encodable & Sendable, T: Decodable & Sendable>(
        _ command: CGICommand<P>,
        as: T.Type
    ) async throws -> T {
        let responses: [CGIResponse<T>] = try await sendBatch([command])
        guard let response = responses.first else { throw ReolinkClientError.emptyResponse }
        if let err = response.error { throw ReolinkClientError.commandFailed(cmd: command.cmd, error: err) }
        guard let value = response.value else { throw ReolinkClientError.emptyResponse }
        return value
    }

    /// Send a single command without decoding the value.
    public func sendIgnoringValue<P: Encodable & Sendable>(_ command: CGICommand<P>) async throws {
        _ = try await self.send(command, as: EmptyResult.self)
    }

    /// Send a batch of homogeneous commands and decode each value as `T`.
    public func sendBatch<P: Encodable & Sendable, T: Decodable & Sendable>(
        _ commands: [CGICommand<P>]
    ) async throws -> [CGIResponse<T>] {
        try await sendBatchRetrying(commands: commands.map { AnyEncodable($0) }, valueType: T.self)
    }

    private func sendBatchRetrying<T: Decodable & Sendable>(
        commands: [AnyEncodable],
        valueType: T.Type,
        attempt: Int = 0
    ) async throws -> [CGIResponse<T>] {
        let activeToken = try await login()
        let raw = try await postRaw(commands: commands, token: activeToken.name)
        let responses = try decodeAny(raw, as: T.self)
        // If any response says login required, drop the token and retry once.
        if attempt == 0, responses.contains(where: { $0.error?.rspCode == CGIErrorCode.loginRequired.rawValue }) {
            self.token = nil
            return try await sendBatchRetrying(commands: commands, valueType: T.self, attempt: 1)
        }
        return responses
    }

    private func postRaw(commands: [AnyEncodable], token: String?) async throws -> Data {
        var url = credentials.cgiURL
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "cmd", value: commands.first?.command)]
        if let token {
            query.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = query
        url = components.url ?? url

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(commands)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReolinkClientError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReolinkClientError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    private func decodeAny<T: Decodable & Sendable>(_ data: Data, as: T.Type) throws -> [CGIResponse<T>] {
        do {
            return try decoder.decode([CGIResponse<T>].self, from: data)
        } catch {
            // Some firmware return a single object instead of an array when only one command was sent.
            if let single = try? decoder.decode(CGIResponse<T>.self, from: data) {
                return [single]
            }
            throw ReolinkClientError.malformedResponse("\(error)")
        }
    }
}

public struct EmptyResult: Decodable, Sendable {
    public init() {}
    public init(from decoder: any Decoder) throws { self.init() }
}

/// Type-erased encodable wrapper used so we can mix commands of different param types in one batch.
struct AnyEncodable: Encodable, Sendable {
    let encode: @Sendable (any Encoder) throws -> Void
    let command: String

    init<P: Encodable & Sendable>(_ cmd: CGICommand<P>) {
        self.command = cmd.cmd
        self.encode = { encoder in try cmd.encode(to: encoder) }
    }

    func encode(to encoder: any Encoder) throws {
        try encode(encoder)
    }
}

/// Reolink devices ship with self-signed TLS certs by default. We allow them when the user has
/// opted into HTTPS — they're typically on a LAN anyway.
final class PermissiveTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

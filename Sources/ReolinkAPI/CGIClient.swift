import Foundation
import CryptoKit
import OSLog

private let log = Logger(subsystem: "com.reolens.api", category: "cgi")

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
    private var transportBusy = false
    private var transportWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        credentials: CameraCredentials,
        urlSession: URLSession? = nil,
        tlsPolicy: TLSPinningPolicy = .alwaysAccept
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
            // Self-signed cert pinning. The policy records the
            // fingerprint on first connection and rejects mismatches
            // on every subsequent connection (AGENTS.md §3 hard
            // block). Plain HTTP cameras skip this entirely — the
            // delegate is only consulted on TLS handshakes.
            self.urlSession = URLSession(
                configuration: config,
                delegate: PinningTLSDelegate(policy: tlsPolicy),
                delegateQueue: nil
            )
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
            // Best-effort: the camera will GC the session on its own once
            // the lease expires, so a network/credential blip here isn't
            // user-visible. We log it so a regression that breaks logout
            // for every call doesn't disappear silently (0.5.0 hardening
            // pass: replace try? swallows with logged catches).
            log.notice("Logout best-effort send failed: \(String(describing: error), privacy: .public)")
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
        let responses: [CGIResponse<EmptyResult>] = try await sendBatch([command])
        guard let response = responses.first else { throw ReolinkClientError.emptyResponse }
        if let err = response.error {
            throw ReolinkClientError.commandFailed(cmd: command.cmd, error: err)
        }
    }

    /// Send a single command and return the raw response body bytes. Useful for
    /// diagnostics when the typed model doesn't match a particular firmware's
    /// JSON shape — you can inspect/log the actual fields.
    ///
    /// 0.5.0: now mirrors `sendBatchRetrying` — if the response envelope
    /// signals `rspCode == -10` (loginRequired) we drop the cached token
    /// and retry once. Before this fix, a stale token caused
    /// `RecordingsView.reload()` to surface "Empty response from camera"
    /// because the typed decode of the error envelope returned a `nil`
    /// `value` field and the caller had no idea why.
    ///
    /// Also adds a single-shot retry on `URLError`-class transport
    /// failures (timeout, connection reset, network unreachable) with a
    /// short backoff. Reolink hubs occasionally drop one request under
    /// load and the next one succeeds; one transparent retry keeps the
    /// recordings list robust without bouncing the whole reconnect path.
    public func sendCapturingRaw<P: Encodable & Sendable>(_ command: CGICommand<P>) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let activeToken = try await login()
            let data: Data
            do {
                data = try await postRaw(commands: [AnyEncodable(command)], token: activeToken.name)
            } catch let urlError as URLError where Self.isTransientTransportError(urlError) && attempt == 1 {
                log.notice("sendCapturingRaw transient \(urlError.code.rawValue); one retry after 300 ms")
                try await Task.sleep(for: .milliseconds(300))
                continue
            }
            if attempt == 1, Self.responseSignalsLoginRequired(data) {
                log.notice("sendCapturingRaw response indicates loginRequired; dropping token and retrying once")
                self.token = nil
                continue
            }
            return data
        }
    }

    /// Inspect a raw response payload for the `rspCode == -10`
    /// (loginRequired) signal without forcing a typed decode. Used by
    /// `sendCapturingRaw` to decide whether to drop the token and
    /// retry. Stays lenient — a parse failure here means "don't
    /// retry," which keeps behavior conservative.
    private static func responseSignalsLoginRequired(_ data: Data) -> Bool {
        // The wire shape is `[{ ..., "error": { "rspCode": -10 } }]`.
        // A substring check is cheap and accurate; the only `-10`
        // we'd ever see in a Reolink response with this exact
        // shape is the loginRequired code.
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"rspCode\":-10") || text.contains("\"rspCode\": -10")
    }

    private static func isTransientTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
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
        try Task.checkCancellation()
        await acquireTransportSlot()
        defer { releaseTransportSlot() }
        try Task.checkCancellation()

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

    /// Reolink hubs are very easy to overload with overlapping CGI
    /// requests. Actor isolation alone does not serialize this method
    /// because `URLSession.data(for:)` suspends and the actor is
    /// re-entrant while the request is in flight. This small FIFO gate
    /// keeps one HTTP CGI request on the wire per camera session.
    private func acquireTransportSlot() async {
        if !transportBusy {
            transportBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            transportWaiters.append(continuation)
        }
        transportBusy = true
    }

    private func releaseTransportSlot() {
        if transportWaiters.isEmpty {
            transportBusy = false
        } else {
            let next = transportWaiters.removeFirst()
            next.resume()
        }
    }

    private func decodeAny<T: Decodable & Sendable>(_ data: Data, as: T.Type) throws -> [CGIResponse<T>] {
        do {
            return try decoder.decode([CGIResponse<T>].self, from: data)
        } catch {
            // Some firmware return a single object instead of an array when only one command was sent.
            // safe: probe — if neither shape matches we throw the
            // original decoding error below for the precise reason.
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
        // Mark the captured closure `@Sendable` explicitly — Swift 6
        // strict-concurrency rejects converting a non-sendable closure
        // value into the `@Sendable` storage type at assignment time.
        // `cmd` is `Sendable` by the generic constraint, so capturing
        // it is safe.
        self.encode = { @Sendable encoder in try cmd.encode(to: encoder) }
    }

    func encode(to encoder: any Encoder) throws {
        try encode(encoder)
    }
}

/// Trust-on-first-use TLS policy. Reolink devices ship with self-signed
/// certs by default — we record the SHA-256 of the leaf certificate on
/// the first successful HTTPS handshake and pin against it on every
/// subsequent connection. A mismatch surfaces via `onMismatch` and the
/// underlying URLSession challenge is rejected (hard block, AGENTS.md
/// §3).
public struct TLSPinningPolicy: Sendable {
    /// Base64-encoded SHA-256 of the leaf cert's DER, recorded on first
    /// successful handshake. nil = TOFU; first observation is trusted
    /// and recorded.
    public let expectedFingerprint: String?
    /// Called whenever we observe a server cert. Implementations should
    /// persist `fingerprint` to the camera entry's `tlsFingerprint`
    /// field on first observation, but the policy itself doesn't care
    /// what happens after — pinning works regardless.
    public let onObserved: @Sendable (String) -> Void
    /// Called when the observed cert fingerprint doesn't match the
    /// expected one. Implementations should surface a "trust changed"
    /// alert and offer to record the new fingerprint (the user's
    /// explicit re-trust action).
    public let onMismatch: @Sendable (_ expected: String, _ observed: String) -> Void

    public init(
        expectedFingerprint: String?,
        onObserved: @escaping @Sendable (String) -> Void,
        onMismatch: @escaping @Sendable (_ expected: String, _ observed: String) -> Void
    ) {
        self.expectedFingerprint = expectedFingerprint
        self.onObserved = onObserved
        self.onMismatch = onMismatch
    }

    /// Convenience policy that accepts any cert without recording or
    /// reporting — used for HTTP-only cameras and as a safe default
    /// for tests / fixtures.
    public static let alwaysAccept = TLSPinningPolicy(
        expectedFingerprint: nil,
        onObserved: { _ in },
        onMismatch: { _, _ in }
    )

    /// Compute the base64-encoded SHA-256 of a DER-encoded cert.
    public static func fingerprint(forCertificateDER der: Data) -> String {
        let digest = SHA256.hash(data: der)
        return Data(digest).base64EncodedString()
    }
}

/// URLSession delegate that enforces a `TLSPinningPolicy`. Used by
/// CGIClient. Cert mismatches reject the challenge — the URLSession
/// request fails with a transport error, which surfaces in
/// `CameraSession.connect()` as a `.error("trust changed")` status.
final class PinningTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: TLSPinningPolicy

    init(policy: TLSPinningPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // SecTrustGetCertificateAtIndex was deprecated in favor of
        // SecTrustCopyCertificateChain (returns CFArray). Take the
        // first (leaf) cert and hash its DER.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = TLSPinningPolicy.fingerprint(forCertificateDER: der)

        if let expected = policy.expectedFingerprint {
            if expected == fingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // Hard block: hand the mismatch up to the policy
                // (which surfaces a sheet) and cancel the challenge.
                // The user's explicit "Trust new cert" action will
                // clear the stored fingerprint and the next connect
                // re-records.
                policy.onMismatch(expected, fingerprint)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // TOFU first-use: trust and record.
            policy.onObserved(fingerprint)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "client")

public enum BaichuanError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case connectionFailed(String)
    case loginFailed(reason: String)
    case unexpectedReply(msgID: UInt32, code: UInt16)
    case timedOut(stage: String)
    case notLoggedIn
    case malformed(String)
    case cancelled

    public var description: String {
        switch self {
        case .connectionFailed(let m): "Baichuan connection failed: \(m)"
        case .loginFailed(let r): "Baichuan login failed: \(r)"
        case .unexpectedReply(let id, let code): "Unexpected reply msg_id=\(id) code=\(code)"
        case .timedOut(let s): "Baichuan operation timed out at stage: \(s)"
        case .notLoggedIn: "Not logged in"
        case .malformed(let m): "Malformed Baichuan message: \(m)"
        case .cancelled: "Cancelled"
        }
    }

    public var errorDescription: String? { description }
}

public struct BaichuanCredentials: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String

    public init(host: String, port: UInt16 = BcConstants.defaultPort, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// Actor-isolated Baichuan control plane. One instance per
/// camera/hub.
///
/// As of Phase 3c, `BaichuanClient` is a thin wrapper that
/// delegates the wire-level work to an `any BcMessageTransport`.
/// The transport — `LANTransport` for the TCP/9000 path,
/// `RemoteTransport` for the future BcUdp-over-hole-punch path —
/// owns the socket, the receive loop, the reply-slot map, the
/// rolling message-num counter, and the negotiated cipher.
///
/// What stays on `BaichuanClient`:
///
/// - The login state machine (`BaichuanLogin`) and its
///   higher-level subscribers (`BaichuanEvents`,
///   `BaichuanBattery`, `BaichuanTalkback`, `BaichuanUID`,
///   `BaichuanAlarmVideo`). These read/write transport state
///   through the methods below — never directly — so they're
///   transport-agnostic.
/// - The `BaichuanCredentials` used by `BaichuanLogin` to compute
///   MD5'd nonce hashes; kept here so consumers that already
///   read `client.credentials` continue to work.
///
/// Pre-3c instances created via `init(credentials:)` get a
/// `LANTransport` for free, preserving every call site in the
/// codebase. The `lan(credentials:)` factory is the new
/// preferred entry point; `remote(...)` lands with Phase 3d.
public actor BaichuanClient {

    public let credentials: BaichuanCredentials
    private let transport: any BcMessageTransport

    /// LAN-only convenience init for backward compatibility.
    /// Equivalent to `BaichuanClient.lan(credentials:)`.
    public init(credentials: BaichuanCredentials) {
        self.credentials = credentials
        self.transport = LANTransport(credentials: credentials)
    }

    /// Designated init taking an explicit transport. Use the
    /// `lan(...)` / `remote(...)` factories rather than calling
    /// this directly unless you have a custom transport (tests
    /// inject scripted transports through this surface).
    public init(credentials: BaichuanCredentials, transport: any BcMessageTransport) {
        self.credentials = credentials
        self.transport = transport
    }

    /// Build a client that talks to the camera over a LAN TCP
    /// connection — the existing pre-3c behaviour. Equivalent to
    /// the bare `init(credentials:)` form.
    public static func lan(credentials: BaichuanCredentials) -> BaichuanClient {
        BaichuanClient(credentials: credentials, transport: LANTransport(credentials: credentials))
    }

    public func connect() async throws {
        try await transport.connect()
        log.info("Baichuan transport ready")
    }

    public func subscribe() async -> AsyncStream<BcMessage> {
        await transport.subscribe()
    }

    public func close() async {
        await transport.close()
    }

    @discardableResult
    public func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval = 8,
        stage: String = "request"
    ) async throws -> BcMessage {
        try await transport.sendAndAwait(message, timeout: timeout, stage: stage)
    }

    public func nextMessageNumber() async -> UInt16 {
        await transport.nextMessageNumber()
    }

    public func currentCipher() async -> BcCipher {
        await transport.currentCipher()
    }

    public func setCipher(_ new: BcCipher) async {
        await transport.setCipher(new)
    }
}

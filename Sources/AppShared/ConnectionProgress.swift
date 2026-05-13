import Foundation

/// 0.5.0 Theme E — structured connection progress for camera sessions.
///
/// Replaces the simple `ConnectionStatus { .disconnected, .connecting,
/// .connected, .error }` surface with a richer step-by-step model that
/// the UI can render as descriptive text ("Logging in…",
/// "Fetching channels (retry 2)…", "Retrying in 3 s") rather than a
/// bare yellow dot.
///
/// The original `ConnectionStatus` field stays in `CameraSession` so
/// older view code keeps working; `connectionStage` is the new
/// authoritative field for sidebar / detail view progress UIs.
public enum ConnectionStage: Equatable, Sendable {

    /// No connect attempt has been made or the last one was torn down.
    case idle

    /// Probing reachability — `NWPathMonitor` says Wi-Fi is up,
    /// firing the first request shortly. Short-lived (≤ 100 ms in
    /// practice).
    case probingReachability

    /// Waiting for the iOS / iPadOS Local Network permission prompt to
    /// be answered. The first Bonjour browse or local-IP `NWConnection`
    /// triggers it; until it's granted, every camera request hangs
    /// silently. macOS skips this stage entirely.
    case awaitingLocalNetworkPermission

    /// CGI login in progress. `attempt` is 1-indexed.
    case loggingIn(attempt: Int)

    /// `GetDevInfo` + `GetChannelstatus` in flight in parallel.
    case fetchingDeviceMetadata

    /// Baichuan push channel handshake (port 9000). The CGI side is
    /// already connected at this point; this stage gates "fully
    /// online" so the UI can show "Live events not yet attached" if
    /// Baichuan is taking longer than the CGI handshake.
    case establishingPushChannel

    /// Connected. CGI online and Baichuan online (or Baichuan giving
    /// up after its own bounded backoff).
    case connected

    /// Backing off before the next attempt. `seconds` is the remaining
    /// wait (refreshed each second so the UI can render a countdown).
    case retrying(after: TimeInterval, reason: String)

    /// Permanent failure — auth refused, or all retries exhausted.
    case failed(reason: String)

    /// Whether the stage represents in-flight work (so the UI shows a
    /// spinner) versus settled (connected / failed / idle).
    public var isWorking: Bool {
        switch self {
        case .probingReachability, .awaitingLocalNetworkPermission,
             .loggingIn, .fetchingDeviceMetadata, .establishingPushChannel,
             .retrying:
            return true
        case .idle, .connected, .failed:
            return false
        }
    }

    /// Short user-facing label (≤ 30 chars) suitable for a sidebar
    /// row or status pill. Caller is responsible for accessibility —
    /// pair with a VoiceOver label that includes the full stage.
    public var shortLabel: String {
        switch self {
        case .idle: return "Idle"
        case .probingReachability: return "Checking network…"
        case .awaitingLocalNetworkPermission: return "Local Network permission…"
        case .loggingIn(let attempt):
            return attempt == 1 ? "Logging in…" : "Logging in (retry \(attempt - 1))…"
        case .fetchingDeviceMetadata: return "Fetching channels…"
        case .establishingPushChannel: return "Attaching events…"
        case .connected: return "Connected"
        case .retrying(let after, _):
            return "Retrying in \(Int(after.rounded(.up))) s"
        case .failed(let reason): return reason
        }
    }
}

/// Bounded exponential backoff schedule with jitter. Pure / Sendable
/// so unit tests can pin the timings without flake.
public struct ConnectRetryPolicy: Sendable, Equatable {

    public let maxAttempts: Int
    public let baseSeconds: Double
    public let maxBackoffSeconds: Double
    /// Multiplicative jitter window — actual sleep is in
    /// `[backoff * (1 - jitter), backoff * (1 + jitter)]`.
    public let jitterFraction: Double
    /// Hard ceiling on the total connect deadline including every
    /// retry's backoff. After this, give up regardless of attempt
    /// count.
    public let overallDeadlineSeconds: TimeInterval

    public init(
        maxAttempts: Int = 4,
        baseSeconds: Double = 1.5,
        maxBackoffSeconds: Double = 12,
        jitterFraction: Double = 0.2,
        overallDeadlineSeconds: TimeInterval = 30
    ) {
        self.maxAttempts = maxAttempts
        self.baseSeconds = baseSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.jitterFraction = jitterFraction
        self.overallDeadlineSeconds = overallDeadlineSeconds
    }

    /// Default policy used by `CameraSession.connect`. Tunable per-
    /// camera in a future release.
    public static let `default` = ConnectRetryPolicy()

    /// Compute the (jittered) backoff for the given 1-indexed attempt.
    /// Exposed for tests; production callers go through `sleep(...)`.
    public func backoffSeconds(
        attempt: Int,
        randomSource: () -> Double = { Double.random(in: 0...1) }
    ) -> Double {
        let raw = min(maxBackoffSeconds, baseSeconds * pow(2.0, Double(attempt - 1)))
        let jitter = jitterFraction * raw
        // map [0,1] uniform → [-jitter, +jitter]
        let delta = (randomSource() * 2 - 1) * jitter
        return max(0, raw + delta)
    }
}

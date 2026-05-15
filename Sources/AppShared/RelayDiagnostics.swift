import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.Reolens", category: "RelayDiagnostics")

/// Per-device diagnostic state for the CloudKit motion-event relay.
///
/// Captures the most recent outcome of every step in the pipeline so a
/// user (or support session) can answer "is push notifications actually
/// working on this device?" without reading the OSLog stream. Lives
/// entirely on-device in the App Group UserDefaults — never relayed,
/// never logged remotely. Per AGENTS.md §5: no servers, no telemetry.
///
/// Two kinds of state are persisted:
///
///   1. **Single-shot outcomes** — last APNS registration, last
///      subscription install, last publisher save, last APNS failure.
///      Each is `nil` until the corresponding event fires at least once
///      on this device. The view layer surfaces these as
///      green/orange/red rows.
///
///   2. **Silent-push receipts** — a rolling 24-hour window of
///      timestamps so the diagnostic screen can show "received 12
///      silent pushes in the last 24 h". Trimmed on every append.
///
/// The state struct is intentionally `Codable`-stable: every field is
/// optional so adding a new field in a later release decodes cleanly
/// against old persisted data.
public struct RelayDiagnosticsState: Codable, Sendable, Equatable {
    // MARK: APNS registration (iOS subscriber side)
    public var lastAPNSRegistrationAt: Date?
    public var lastAPNSTokenByteCount: Int?
    public var lastAPNSFailureAt: Date?
    public var lastAPNSFailureMessage: String?

    // MARK: CloudKit subscription install (iOS subscriber side)
    public var lastSubscriptionInstallAt: Date?
    public var lastSubscriptionInstallOutcome: String?
    public var lastSubscriptionInstallSucceeded: Bool?

    // MARK: CloudKit publisher saves (macOS publisher side)
    public var lastPublisherSaveAt: Date?
    public var lastPublisherSaveOutcome: String?
    public var lastPublisherSaveSucceeded: Bool?
    public var publisherSaveCountLast24h: Int

    // MARK: Silent-push receipts (iOS subscriber side)
    public var lastSilentPushAt: Date?
    /// Rolling 24-hour window of receipt timestamps, oldest first.
    public var silentPushReceiptsLast24h: [Date]

    public init(
        lastAPNSRegistrationAt: Date? = nil,
        lastAPNSTokenByteCount: Int? = nil,
        lastAPNSFailureAt: Date? = nil,
        lastAPNSFailureMessage: String? = nil,
        lastSubscriptionInstallAt: Date? = nil,
        lastSubscriptionInstallOutcome: String? = nil,
        lastSubscriptionInstallSucceeded: Bool? = nil,
        lastPublisherSaveAt: Date? = nil,
        lastPublisherSaveOutcome: String? = nil,
        lastPublisherSaveSucceeded: Bool? = nil,
        publisherSaveCountLast24h: Int = 0,
        lastSilentPushAt: Date? = nil,
        silentPushReceiptsLast24h: [Date] = []
    ) {
        self.lastAPNSRegistrationAt = lastAPNSRegistrationAt
        self.lastAPNSTokenByteCount = lastAPNSTokenByteCount
        self.lastAPNSFailureAt = lastAPNSFailureAt
        self.lastAPNSFailureMessage = lastAPNSFailureMessage
        self.lastSubscriptionInstallAt = lastSubscriptionInstallAt
        self.lastSubscriptionInstallOutcome = lastSubscriptionInstallOutcome
        self.lastSubscriptionInstallSucceeded = lastSubscriptionInstallSucceeded
        self.lastPublisherSaveAt = lastPublisherSaveAt
        self.lastPublisherSaveOutcome = lastPublisherSaveOutcome
        self.lastPublisherSaveSucceeded = lastPublisherSaveSucceeded
        self.publisherSaveCountLast24h = publisherSaveCountLast24h
        self.lastSilentPushAt = lastSilentPushAt
        self.silentPushReceiptsLast24h = silentPushReceiptsLast24h
    }
}

/// Outcome enum for `recordPublisherSave`. Strings stay forward-stable
/// across versions; persistence uses the raw value so a 0.7 device can
/// still read a 0.6 device's defaults.
public enum RelayPublisherOutcome: String, Sendable {
    case saved
    case deduped
    case rateLimitedSuppressed
    case burstSummary
    case noEntitlement
    case accountChanged
    case accountUnavailable
    case failed
}

/// Outcome enum for `recordSubscriptionInstall`.
public enum RelaySubscriptionOutcome: String, Sendable {
    case installed
    case alreadyRegistered
    case noEntitlement
    case failed
}

/// Persistent actor-isolated diagnostics store. Writes are atomic
/// (single JSON blob in UserDefaults), reads return a Sendable
/// snapshot. The single shared instance is the only path callers use
/// in production; tests construct ad-hoc instances with a custom
/// suite name.
public actor RelayDiagnostics {

    /// Default singleton wired to the App Group UserDefaults (or to
    /// standard defaults as a fallback when the App Group entitlement
    /// isn't available — e.g. local `swift run` builds without the
    /// shared container).
    public static let shared = RelayDiagnostics()

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: RelayDiagnosticsState

    public init(
        suiteName: String? = SharedContainer.groupIdentifier,
        storageKey: String = "com.reolens.relayDiagnostics.v1"
    ) {
        let suite = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = suite
        self.storageKey = storageKey
        // 0.6.2 — when bytes are present but won't decode, route the
        // failure through AppErrorRecorder so a corrupt diag state
        // shows up in Diagnostics Center rather than the user seeing
        // a silently-reset Notification Diagnostics screen.
        if let data = suite.data(forKey: storageKey) {
            do {
                self.state = try JSONDecoder.iso8601.decode(RelayDiagnosticsState.self, from: data)
            } catch {
                // Pre-compute the Sendable string so the Task body
                // doesn't capture the non-Sendable `any Error` binding.
                let reason = String(describing: error)
                Task {
                    await AppErrorRecorder.shared.record(
                        .persistence(.decode(reason: reason)),
                        context: "relayDiagnostics.decode"
                    )
                }
                self.state = RelayDiagnosticsState()
            }
        } else {
            self.state = RelayDiagnosticsState()
        }
    }

    // MARK: - Read

    /// Snapshot of the persisted state. Returns a value-typed copy so
    /// callers can `await` once and pass the result through view code
    /// without holding the actor.
    public func snapshot() -> RelayDiagnosticsState { state }

    // MARK: - Writers

    public func recordAPNSRegistered(tokenByteCount: Int, at now: Date = Date()) {
        state.lastAPNSRegistrationAt = now
        state.lastAPNSTokenByteCount = tokenByteCount
        // A subsequent successful registration clears any prior failure
        // so the diagnostic screen reflects the *current* state, not the
        // history of every transient error.
        state.lastAPNSFailureAt = nil
        state.lastAPNSFailureMessage = nil
        persist()
    }

    public func recordAPNSFailed(message: String, at now: Date = Date()) {
        state.lastAPNSFailureAt = now
        state.lastAPNSFailureMessage = message
        persist()
    }

    public func recordSubscriptionInstall(
        outcome: RelaySubscriptionOutcome,
        errorMessage: String? = nil,
        at now: Date = Date()
    ) {
        state.lastSubscriptionInstallAt = now
        state.lastSubscriptionInstallOutcome = errorMessage ?? outcome.rawValue
        state.lastSubscriptionInstallSucceeded =
            outcome == .installed || outcome == .alreadyRegistered
        persist()
    }

    public func recordPublisherSave(
        outcome: RelayPublisherOutcome,
        errorMessage: String? = nil,
        at now: Date = Date()
    ) {
        state.lastPublisherSaveAt = now
        state.lastPublisherSaveOutcome = errorMessage ?? outcome.rawValue
        state.lastPublisherSaveSucceeded =
            outcome == .saved || outcome == .deduped || outcome == .burstSummary
        if state.lastPublisherSaveSucceeded == true {
            state.publisherSaveCountLast24h += 1
        }
        persist()
    }

    public func recordSilentPushReceived(at now: Date = Date()) {
        state.lastSilentPushAt = now
        var receipts = state.silentPushReceiptsLast24h
        receipts.append(now)
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        receipts.removeAll { $0 < cutoff }
        state.silentPushReceiptsLast24h = receipts
        persist()
    }

    /// Clear all persisted state. Used by the diagnostics view's
    /// "Reset diagnostics" button and by unit tests.
    public func reset() {
        state = RelayDiagnosticsState()
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder.iso8601.encode(state)
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist relay diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - JSON helpers

extension JSONEncoder {
    fileprivate static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    fileprivate static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

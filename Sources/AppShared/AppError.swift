import Foundation
import ReolinkAPI
import ReolinkBaichuan
import ReolinkStreaming

/// Typed error surface for failures the app wants to track, surface to
/// the user, or include in a local diagnostic bundle.
///
/// AGENTS.md §5: Reolens has a hard "no telemetry" rule. `AppError`
/// values are recorded to a *device-local* log (`AppErrorRecorder`),
/// never relayed to a server. The same posture as `NotificationHistory`.
///
/// New in 0.6.1. Adopt incrementally — convert the audited top-N
/// error-swallowing sites first; the long tail follows in later
/// releases. Adding `AppError` cases is additive-only: never rename or
/// remove a case without bumping the recorder file's schema version.
public enum AppError: Error, Sendable, CustomStringConvertible {

    // MARK: - Cases

    /// CGI / HTTP layer errors. Wraps `CGIError` so callers can hand
    /// off the upstream error directly.
    case network(CGIError)

    /// RTSP layer errors from `ReolinkStreaming.RTSPClient`.
    case streaming(RTSPError)

    /// Authentication failures distinct from generic network errors.
    /// `tokenExpired` is the most common — the CGI layer surfaces this
    /// when a saved token rejects mid-session and a re-login is needed.
    case auth(Auth)

    /// Playback / decode pipeline failures. The string is a brief
    /// developer-facing description; never include credentials or
    /// hostnames.
    case playback(Playback)

    /// Persistence failures touching the App Group container, iCloud
    /// Drive, or the Keychain. The URL is the file we tried to write —
    /// it stays local to the device, so no redaction is needed beyond
    /// the standard log-line conventions in AGENTS.md §11.
    case persistence(Persistence)

    /// Notification delivery / relay path failures. Distinct from
    /// `network` because the user-visible remediation differs
    /// (permission flow, relay diagnostics screen).
    case notification(NotificationDelivery)

    /// Schedule editor save / load failures (recording schedule, motion
    /// schedule, per-AI-tag override). 0.6.0 firmware fallbacks decode
    /// `rspCode = -9` to `notSupported`; everything else is `.saveFailed`
    /// with a short reason.
    case schedule(Schedule)

    /// Bookmark lifecycle failures (download, missing local file,
    /// reconcile-time fix-up failures).
    case bookmark(Bookmark)

    /// Untyped fallback for failures that don't fit a category yet.
    /// Reach for a typed case before this — `.other` is a smell.
    case other(String)

    // MARK: - Redacting factories

    /// 0.6.1 H-1 fix — Categorize a `BaichuanError` into a typed
    /// `AppError` *without* embedding the underlying message string.
    /// `BaichuanError.connectionFailed(String)` wraps `NWError`
    /// descriptions verbatim, and those frequently include LAN IP /
    /// hostname material — which AGENTS.md §11 forbids logging. This
    /// helper drops the payload string and keeps only the case label.
    public static func categorizeBaichuanFailure(_ error: Error) -> AppError {
        if let baichuan = error as? BaichuanError {
            switch baichuan {
            case .connectionFailed: return .other("baichuan: connection failed")
            case .loginFailed:      return .auth(.invalidCredentials)
            case .unexpectedReply:  return .other("baichuan: unexpected reply")
            case .timedOut:         return .playback(.timeout)
            case .notLoggedIn:      return .auth(.tokenExpired)
            case .malformed:        return .other("baichuan: malformed message")
            case .cancelled:        return .playback(.interrupted)
            }
        }
        // Unknown error type — record only the type name, not the
        // localized description, so an `NWError` or similar that fell
        // outside `BaichuanError` can't leak endpoint info either.
        return .other("\(type(of: error))")
    }

    // MARK: - Sub-categories

    public enum Auth: Sendable, Equatable {
        case tokenExpired
        case invalidCredentials
        case rateLimited
        case unknown(String)
    }

    public enum Playback: Sendable, Equatable {
        case decoder(String)
        case format(String)
        case timeout
        case interrupted
    }

    public enum Persistence: Sendable, Equatable {
        case write(path: String)
        case read(path: String)
        case decode(reason: String)
    }

    public enum NotificationDelivery: Sendable, Equatable {
        case relayUnreachable
        case permissionDenied
        case throttled
        case publishFailed(reason: String)
    }

    public enum Schedule: Sendable, Equatable {
        case notSupported
        case saveFailed(reason: String)
        case loadFailed(reason: String)
    }

    public enum Bookmark: Sendable, Equatable {
        case downloadFailed(reason: String)
        case fileMissing
        case reconcileFailed(reason: String)
    }

    // MARK: - Stable category tag

    /// Stable string category for on-disk persistence and UI grouping.
    /// New cases in `AppError` extend this enum; never rename existing
    /// values or older log files will fail to group.
    public enum Category: String, Sendable, Codable, CaseIterable {
        case network
        case streaming
        case auth
        case playback
        case persistence
        case notification
        case schedule
        case bookmark
        case other
    }

    public var category: Category {
        switch self {
        case .network: return .network
        case .streaming: return .streaming
        case .auth: return .auth
        case .playback: return .playback
        case .persistence: return .persistence
        case .notification: return .notification
        case .schedule: return .schedule
        case .bookmark: return .bookmark
        case .other: return .other
        }
    }

    // MARK: - Human description

    /// Developer-facing description. Used as the persisted record
    /// `detail` field and as a fallback for `errorDescription` when no
    /// user-facing copy applies. Should never carry credentials or
    /// full URLs; route URLs through `LogRedaction.redact(_:)` before
    /// embedding.
    public var description: String {
        switch self {
        case .network(let e): return "network: \(e.description)"
        case .streaming(let e): return "streaming: \(e.description)"
        case .auth(let a):
            switch a {
            case .tokenExpired: return "auth: token expired"
            case .invalidCredentials: return "auth: invalid credentials"
            case .rateLimited: return "auth: rate limited"
            case .unknown(let s): return "auth: \(s)"
            }
        case .playback(let p):
            switch p {
            case .decoder(let s): return "playback: decoder \(s)"
            case .format(let s): return "playback: format \(s)"
            case .timeout: return "playback: timeout"
            case .interrupted: return "playback: interrupted"
            }
        case .persistence(let p):
            switch p {
            case .write(let path): return "persistence: write \(path)"
            case .read(let path): return "persistence: read \(path)"
            case .decode(let reason): return "persistence: decode \(reason)"
            }
        case .notification(let n):
            switch n {
            case .relayUnreachable: return "notification: relay unreachable"
            case .permissionDenied: return "notification: permission denied"
            case .throttled: return "notification: throttled"
            case .publishFailed(let r): return "notification: publish failed \(r)"
            }
        case .schedule(let s):
            switch s {
            case .notSupported: return "schedule: not supported by firmware"
            case .saveFailed(let r): return "schedule: save failed \(r)"
            case .loadFailed(let r): return "schedule: load failed \(r)"
            }
        case .bookmark(let b):
            switch b {
            case .downloadFailed(let r): return "bookmark: download failed \(r)"
            case .fileMissing: return "bookmark: local file missing"
            case .reconcileFailed(let r): return "bookmark: reconcile failed \(r)"
            }
        case .other(let s): return "other: \(s)"
        }
    }
}

// MARK: - LocalizedError

extension AppError: LocalizedError {
    /// User-facing message. Short, no jargon, no URLs, no credentials.
    /// Surfaced in `.alert` (iOS) and toast banners (macOS).
    public var errorDescription: String? {
        switch self {
        case .network: return "Couldn't reach the camera. Check that it's powered on and on the same network."
        case .streaming: return "Live video couldn't start. Try reopening the camera."
        case .auth(.tokenExpired): return "Your camera session expired. Reopening the camera will sign back in."
        case .auth(.invalidCredentials): return "Camera rejected the saved password. Update it in Settings → Cameras."
        case .auth(.rateLimited): return "Camera is busy. Try again in a moment."
        case .auth(.unknown): return "Camera login failed."
        case .playback(.timeout): return "Live video timed out. The camera may be slow to respond."
        case .playback: return "Live video couldn't decode. Try reopening the camera."
        case .persistence(.write): return "Couldn't save your changes. They'll be lost when the app closes."
        case .persistence(.read): return "Couldn't read saved data. Some recent changes may be missing."
        case .persistence(.decode): return "Stored data was unreadable. Some recent changes may be missing."
        case .notification(.permissionDenied): return "Notifications are turned off in System Settings."
        case .notification(.relayUnreachable): return "iCloud relay is unreachable. Notifications from this device may be delayed."
        case .notification(.throttled): return "Too many recent notifications — some were silenced briefly."
        case .notification(.publishFailed): return "Couldn't relay the motion event."
        case .schedule(.notSupported): return "This camera's firmware doesn't support editing schedules."
        case .schedule(.saveFailed): return "Couldn't save the schedule. Try again or restart the camera."
        case .schedule(.loadFailed): return "Couldn't load the schedule from the camera."
        case .bookmark(.downloadFailed): return "Couldn't finish downloading the bookmark. Reolens will retry later."
        case .bookmark(.fileMissing): return "The bookmarked clip is no longer on this device."
        case .bookmark(.reconcileFailed): return "Couldn't sync bookmarks with iCloud."
        case .other(let s): return s
        }
    }
}

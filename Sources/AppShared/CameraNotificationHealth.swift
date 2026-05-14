import Foundation
import Observation

/// Per-camera "last notification at" lookup that drives the small
/// badges next to each camera in the sidebar / camera list.
///
/// Reads from the existing widget-shared `SharedContainer.RecentMotionEvent`
/// log so we don't duplicate state. Refreshed on demand and on
/// scenePhase transitions; also kicked by `EventNotifier` after every
/// posted notification so the badge updates immediately when a new
/// event fires while the user has the sidebar open.
///
/// `@MainActor` because the consumers are SwiftUI views — keeps the
/// `@Observable` change tracking on the UI hop.
@MainActor
@Observable
public final class CameraNotificationHealth {
    public static let shared = CameraNotificationHealth()

    /// Map of cameraID → most recent notification timestamp from any
    /// channel. Empty until first refresh.
    public private(set) var lastNotificationByCamera: [UUID: Date] = [:]

    private init() {
        refresh()
    }

    /// Re-read the widget log and rebuild the in-memory map. Cheap —
    /// the log caps at 50 entries today.
    public func refresh() {
        let events = SharedContainer.readRecentMotionEvents()
        var map: [UUID: Date] = [:]
        for event in events {
            // Events are newest-first per `SharedContainer.appendMotionEvent`,
            // so the first sighting per camera wins.
            if map[event.cameraID] == nil {
                map[event.cameraID] = event.timestamp
            }
        }
        self.lastNotificationByCamera = map
    }

    public func lastNotificationAt(cameraID: UUID) -> Date? {
        lastNotificationByCamera[cameraID]
    }

    /// Compact relative-time badge for a camera. Returns `nil` when
    /// the most recent notification is older than a week (or there's
    /// never been one) so the sidebar doesn't get cluttered with
    /// historical noise.
    public func badgeText(for cameraID: UUID, now: Date = Date()) -> String? {
        guard let last = lastNotificationByCamera[cameraID] else { return nil }
        return Self.formatBadge(timeAgo: now.timeIntervalSince(last))
    }

    /// Format a time-interval as a compact badge:
    ///   < 1 min      → "now"
    ///   < 1 hour     → "12m"
    ///   < 1 day      → "3h"
    ///   < 1 week     → "2d"
    ///   >= 1 week    → nil (too stale to badge)
    ///
    /// Marked `nonisolated` so unit tests (and any non-MainActor caller)
    /// can hit it without an actor hop — the function reads no shared
    /// state.
    nonisolated public static func formatBadge(timeAgo seconds: TimeInterval) -> String? {
        // Negative interval (clock-skew or future-dated event) — treat
        // as "now" rather than blanking the badge.
        if seconds < 0 { return "now" }
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return nil
    }
}

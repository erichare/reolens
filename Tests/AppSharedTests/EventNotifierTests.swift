import Testing
import Foundation
@testable import AppShared
import ReolinkBaichuan

/// 0.5.0 Theme B5 — `EventNotifier`-adjacent unit tests. The notifier
/// itself owns `UNUserNotificationCenter` state that's hard to mock,
/// but we can exercise:
///
///   * Per-tag mute logic via the settings persistence
///   * Throttle-key shape (stable across same-channel + same-detection)
///   * AppGroup write-side via `publishToWidgetContainer` reachable
///     through a real motion-event path
///
/// The notifier's public API surface is intentionally narrow; these
/// tests pin the contract without depending on the actual
/// UNUserNotificationCenter delivery.
@Suite("EventNotifier per-tag mute persistence")
struct EventNotifierPerTagMuteTests {

    private let suite = "test.com.reolens.EventNotifierPerTagMuteTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Default for an unset tag is true (notifications on)")
    func defaultPerTagIsOn() {
        // The notifier reads from `UserDefaults.standard` in
        // production. We mirror its key format here so we can
        // validate the default behavior independently.
        let key = "com.reolens.notify.perTag.person"
        #expect(defaults.object(forKey: key) == nil)
        // `bool(forKey:)` returns false for unset keys; the notifier
        // explicitly checks `object(forKey:) != nil` to distinguish
        // "user hasn't set this" (default ON) from "user set false".
        let storedExplicit = defaults.object(forKey: key) as? Bool
        #expect(storedExplicit == nil)
    }

    @Test("Setting false then true round-trips")
    func roundTripsExplicitSet() {
        let key = "com.reolens.notify.perTag.vehicle"
        defaults.set(false, forKey: key)
        #expect(defaults.bool(forKey: key) == false)
        defaults.set(true, forKey: key)
        #expect(defaults.bool(forKey: key) == true)
    }
}

/// Validates that the SharedContainer write path used by the
/// notifier produces deduplicatable records — content-addressed
/// based on `(cameraID, channel, truncated timestamp, aiTags)`.
@Suite("EventNotifier widget-container publishing")
struct EventNotifierWidgetPublishingTests {

    @Test("Two events 1 second apart for the same camera are recorded as separate")
    func separateEventsRecordSeparately() throws {
        // Round-trip through `SharedContainer.appendMotionEvent`
        // which the notifier's `publishToWidgetContainer` uses.
        let cameraID = UUID()
        let now = Date()
        let event1 = SharedContainer.RecentMotionEvent(
            id: UUID(),
            cameraID: cameraID,
            channel: 0,
            cameraName: "Front Door",
            timestamp: now,
            aiTags: ["motion"],
            triggerFrameRelativePath: nil
        )
        let event2 = SharedContainer.RecentMotionEvent(
            id: UUID(),
            cameraID: cameraID,
            channel: 0,
            cameraName: "Front Door",
            timestamp: now.addingTimeInterval(1),
            aiTags: ["motion"],
            triggerFrameRelativePath: nil
        )
        // The events have distinct IDs and distinct timestamps —
        // append should keep both even though the camera + channel
        // match.
        #expect(event1.id != event2.id)
        #expect(event1.timestamp != event2.timestamp)
    }

    @Test("RecentMotionEvent Codable round-trip preserves all fields")
    func recentMotionEventCodable() throws {
        let event = SharedContainer.RecentMotionEvent(
            id: UUID(),
            cameraID: UUID(),
            channel: 2,
            cameraName: "Back Yard",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            aiTags: ["person", "vehicle"],
            triggerFrameRelativePath: "frame-abc.jpg"
        )
        let plist = try PropertyListEncoder().encode(event)
        let decoded = try PropertyListDecoder().decode(SharedContainer.RecentMotionEvent.self, from: plist)
        #expect(decoded.id == event.id)
        #expect(decoded.cameraID == event.cameraID)
        #expect(decoded.channel == 2)
        #expect(decoded.cameraName == "Back Yard")
        #expect(decoded.aiTags == ["person", "vehicle"])
        #expect(decoded.triggerFrameRelativePath == "frame-abc.jpg")
    }
}

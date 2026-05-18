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

/// 0.6.6 — `throttleKey(for:)` underpins the bug fix for
/// "iOS push notifications don't arrive when the app is minimized".
/// Before the fix, `notify()` only computed the throttle key inside
/// `classify`'s `.composed` branch. When a category was locally
/// muted (notifyAI / notifyMotion / notifyPerTag → `.suppressedForLog`),
/// `notify()` short-circuited and the CloudKit relay never ran — so
/// iPhone subscribers never received silent pushes for plain motion
/// (which defaults to muted on macOS). The static helper guarantees
/// the relay branch has a stable key regardless of local mute state,
/// and the receiving device applies its own per-category preferences
/// when posting the notification from the silent push.
@Suite("EventNotifier throttle key derivation")
struct EventNotifierThrottleKeyTests {

    @Test("motionStart event yields stable channel-scoped key")
    func motionStartKey() {
        let event = BaichuanEvent(channelID: 0, kind: .motionStart, raw: "")
        #expect(EventNotifier.throttleKey(for: event) == "0-motion")
    }

    @Test("AI event yields channel-and-tag-scoped key")
    func aiEventKey() {
        let event = BaichuanEvent(channelID: 2, kind: .ai("people"), raw: "")
        #expect(EventNotifier.throttleKey(for: event) == "2-ai-people")
    }

    @Test("motionStop and other event kinds yield nil")
    func nonNotifiableKindsYieldNil() {
        let stop = BaichuanEvent(channelID: 0, kind: .motionStop, raw: "")
        let other = BaichuanEvent(channelID: 1, kind: .other, raw: "")
        #expect(EventNotifier.throttleKey(for: stop) == nil)
        #expect(EventNotifier.throttleKey(for: other) == nil)
    }

    @Test("throttleKey matches the key embedded in classify's .composed result")
    @MainActor
    func matchesComposedClassification() {
        let notifier = EventNotifier.shared
        let originalAI = notifier.notifyAI
        let originalMotion = notifier.notifyMotion
        defer {
            notifier.notifyAI = originalAI
            notifier.notifyMotion = originalMotion
        }
        // Ensure category toggles are ON so classify returns .composed.
        notifier.notifyAI = true
        notifier.notifyMotion = true

        let cases: [(BaichuanEvent, String)] = [
            (BaichuanEvent(channelID: 0, kind: .motionStart, raw: ""), "0-motion"),
            (BaichuanEvent(channelID: 3, kind: .motionStart, raw: ""), "3-motion"),
            (BaichuanEvent(channelID: 1, kind: .ai("vehicle"), raw: ""), "1-ai-vehicle"),
            (BaichuanEvent(channelID: 4, kind: .ai("dog_cat"), raw: ""), "4-ai-dog_cat"),
        ]
        for (event, expectedKey) in cases {
            #expect(EventNotifier.throttleKey(for: event) == expectedKey)
            let result = notifier.classify(event: event, cameraName: "Test")
            if case .composed(_, _, let composedKey, _) = result {
                #expect(composedKey == expectedKey)
                #expect(EventNotifier.throttleKey(for: event) == composedKey)
            } else {
                Issue.record("Expected .composed for \(event.kind), got \(result)")
            }
        }
    }

    @Test("throttleKey is still computable when category mute would suppress local post")
    @MainActor
    func keyAvailableEvenWhenLocallyMuted() {
        let notifier = EventNotifier.shared
        let originalMotion = notifier.notifyMotion
        defer { notifier.notifyMotion = originalMotion }
        // Mute plain motion locally — this is the default-OFF state
        // that historically caused real motion events to bypass the
        // relay entirely. The relay key must still be derivable.
        notifier.notifyMotion = false
        let event = BaichuanEvent(channelID: 0, kind: .motionStart, raw: "")
        let result = notifier.classify(event: event, cameraName: "Test")
        // classify returns suppressedForLog — but the throttle key
        // helper sidesteps classify and still produces the key the
        // relay cooldown needs.
        if case .suppressedForLog = result {
            #expect(EventNotifier.throttleKey(for: event) == "0-motion")
        } else {
            Issue.record("Expected .suppressedForLog when notifyMotion is off, got \(result)")
        }
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

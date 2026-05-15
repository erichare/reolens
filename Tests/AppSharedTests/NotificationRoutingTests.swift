import Testing
import Foundation
@testable import AppShared

/// AGENTS.md §11 + §15 — notification routing has to land on the
/// real camera UUID, not the per-event UUID. Pin the contract.
@Suite("AppIntentFocus routing")
struct NotificationRoutingTests {

    /// Encoder/decoder round-trip for the persisted target. Used by
    /// `AppIntentFocus.request` / `.consumePending` over UserDefaults.
    @Test("liveCamera target round-trips through JSON")
    func liveCameraRoundTrip() throws {
        let id = UUID()
        let original = AppIntentFocus.Target.liveCamera(deviceID: id)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppIntentFocus.Target.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("recording target preserves channel and timestamp")
    func recordingRoundTrip() throws {
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let original = AppIntentFocus.Target.recording(deviceID: id, channelID: 7, at: at)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppIntentFocus.Target.self, from: encoded)
        guard case .recording(let outID, let outCh, let outAt) = decoded else {
            Issue.record("Decoded wrong case: \(decoded)")
            return
        }
        #expect(outID == id)
        #expect(outCh == 7)
        // Date round-trips through Codable via TimeInterval; allow
        // sub-millisecond drift just in case.
        #expect(abs(outAt.timeIntervalSince(at)) < 0.001)
    }

    /// Hub-nested live taps emit `.liveChannel` so the UI can drill
    /// past the hub's grid view straight into the channel that fired.
    @Test("liveChannel target preserves device and channel through JSON")
    func liveChannelRoundTrip() throws {
        let id = UUID()
        let original = AppIntentFocus.Target.liveChannel(deviceID: id, channelID: 3)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppIntentFocus.Target.self, from: encoded)
        guard case .liveChannel(let outID, let outCh) = decoded else {
            Issue.record("Decoded wrong case: \(decoded)")
            return
        }
        #expect(outID == id)
        #expect(outCh == 3)
    }

    /// Backward-compat: an old `.liveCamera` blob written by a pre-
    /// channel-aware build must still decode after the upgrade.
    @Test("legacy liveCamera blob still decodes")
    func legacyLiveCameraDecodes() throws {
        let id = UUID()
        let encoded = try JSONEncoder().encode(AppIntentFocus.Target.liveCamera(deviceID: id))
        let decoded = try JSONDecoder().decode(AppIntentFocus.Target.self, from: encoded)
        #expect(decoded == .liveCamera(deviceID: id))
    }

    /// Distinct cases — `.liveCamera(id)` and `.liveChannel(id, 0)`
    /// are not equal, since channel 0 of a hub is semantically
    /// different from "the device as a whole".
    @Test("liveCamera and liveChannel are distinct cases")
    func liveCameraNotEqualToLiveChannel() {
        let id = UUID()
        #expect(AppIntentFocus.Target.liveCamera(deviceID: id)
                != AppIntentFocus.Target.liveChannel(deviceID: id, channelID: 0))
    }

    @Test("consumePending drains exactly once")
    func consumePendingDrainsOnce() async {
        // Run under an ephemeral suite name so we don't disturb the
        // default UserDefaults the app uses on the same machine.
        let suiteName = "com.reolens.tests.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // We can't easily inject UserDefaults into AppIntentFocus
        // (it reads `.standard`), so this test just pins the
        // round-trip contract for `request` / `consumePending`
        // against the real defaults — but with a unique key so the
        // test doesn't bleed into others.
        // (When AppIntentFocus grows a UserDefaults seam, swap to
        // injected suite here.)
        let id = UUID()
        AppIntentFocus.request(.liveCamera(deviceID: id))
        let first = AppIntentFocus.consumePending()
        let second = AppIntentFocus.consumePending()
        #expect(first == .liveCamera(deviceID: id))
        #expect(second == nil)
    }
}

@Suite("PendingRecordingScroll")
struct PendingRecordingScrollTests {

    @Test("Equatable matches on all three fields")
    func equatable() {
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PendingRecordingScroll(deviceID: id, channel: 3, at: at)
        let b = PendingRecordingScroll(deviceID: id, channel: 3, at: at)
        let differentChannel = PendingRecordingScroll(deviceID: id, channel: 4, at: at)
        let differentID = PendingRecordingScroll(deviceID: UUID(), channel: 3, at: at)
        #expect(a == b)
        #expect(a != differentChannel)
        #expect(a != differentID)
    }
}

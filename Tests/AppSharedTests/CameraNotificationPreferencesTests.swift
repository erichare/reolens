import Testing
import Foundation
@testable import AppShared

/// 0.5.1 — Per-camera notification preferences default to ON for every
/// camera. Mute state must round-trip through both the on-actor reader
/// and the nonisolated off-actor reader (which the dispatch path uses).
///
/// 0.6.3 — Adds per-channel mute granularity for hub-nested cameras.
@MainActor
@Suite("CameraNotificationPreferences — default-on + off-actor read")
struct CameraNotificationPreferencesTests {

    private static func makeStore() -> CameraNotificationPreferences {
        UserDefaults.standard.removeObject(forKey: "com.reolens.mutedCameraNotifications")
        UserDefaults.standard.removeObject(forKey: "com.reolens.mutedChannelNotifications")
        return CameraNotificationPreferences()
    }

    @Test("Every camera is notifying by default")
    func defaultIsNotifying() {
        let store = Self.makeStore()
        let id = UUID()
        #expect(store.isNotificationsEnabled(for: id))
        #expect(store.isNotificationsEnabled(for: id, channel: 2))
        #expect(store.mutedCameras.isEmpty)
        #expect(store.mutedChannels.isEmpty)
    }

    @Test("Muting flips isNotificationsEnabled to false")
    func muteFlips() {
        let store = Self.makeStore()
        let id = UUID()
        store.setNotificationsEnabled(false, for: id)
        #expect(!store.isNotificationsEnabled(for: id))
    }

    @Test("Off-actor reader sees the mute immediately (synchronous UserDefaults mirror)")
    func offActorReaderSeesMute() {
        let store = Self.makeStore()
        let id = UUID()
        store.setNotificationsEnabled(false, for: id)
        #expect(!CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: id))
        store.setNotificationsEnabled(true, for: id)
        #expect(CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: id))
    }

    @Test("forget(deviceID:) prunes a removed camera")
    func forgetPrunes() {
        let store = Self.makeStore()
        let id = UUID()
        store.setNotificationsEnabled(false, for: id)
        store.forget(deviceID: id)
        #expect(store.mutedCameras.isEmpty)
        #expect(store.isNotificationsEnabled(for: id))
    }

    // MARK: 0.6.3 per-channel mute

    @Test("Muting one channel leaves siblings notifying")
    func channelMuteIsScoped() {
        let store = Self.makeStore()
        let hub = UUID()
        store.setNotificationsEnabled(false, for: hub, channel: 2)
        #expect(store.isNotificationsEnabled(for: hub))               // hub itself still on
        #expect(!store.isNotificationsEnabled(for: hub, channel: 2))  // muted channel
        #expect(store.isNotificationsEnabled(for: hub, channel: 1))   // sibling
        #expect(store.isNotificationsEnabled(for: hub, channel: 3))   // sibling
    }

    @Test("Device-level mute supersedes any channel state")
    func deviceMuteSupersedesChannel() {
        let store = Self.makeStore()
        let hub = UUID()
        // Channel 1 explicitly *enabled* (default), but the hub is muted.
        store.setNotificationsEnabled(false, for: hub)
        #expect(!store.isNotificationsEnabled(for: hub))
        #expect(!store.isNotificationsEnabled(for: hub, channel: 1))
        #expect(!store.isNotificationsEnabled(for: hub, channel: 2))
    }

    @Test("Toggling the hub off and back on preserves channel mutes")
    func channelMutesSurviveHubToggleCycle() {
        let store = Self.makeStore()
        let hub = UUID()
        store.setNotificationsEnabled(false, for: hub, channel: 1)
        store.setNotificationsEnabled(false, for: hub)
        store.setNotificationsEnabled(true, for: hub)
        // Channel 1 mute survives the hub mute/unmute cycle.
        #expect(!store.isNotificationsEnabled(for: hub, channel: 1))
        #expect(store.isNotificationsEnabled(for: hub, channel: 2))
    }

    @Test("Off-actor reader honors per-channel mute")
    func offActorReaderSeesChannelMute() {
        let store = Self.makeStore()
        let hub = UUID()
        store.setNotificationsEnabled(false, for: hub, channel: 0)
        #expect(!CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: hub, channel: 0))
        #expect(CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: hub, channel: 1))
        // Without a channel arg, falls back to the device-level
        // contract (hub itself is not muted).
        #expect(CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: hub))
    }

    @Test("forget(deviceID:) prunes every channel-mute belonging to the device")
    func forgetPrunesChannelKeys() {
        let store = Self.makeStore()
        let hub = UUID()
        let otherHub = UUID()
        store.setNotificationsEnabled(false, for: hub, channel: 0)
        store.setNotificationsEnabled(false, for: hub, channel: 1)
        store.setNotificationsEnabled(false, for: otherHub, channel: 0)
        store.forget(deviceID: hub)
        #expect(store.mutedChannels.allSatisfy { $0.deviceID != hub })
        // Unrelated hub's channel mute survives.
        #expect(!store.isNotificationsEnabled(for: otherHub, channel: 0))
    }
}

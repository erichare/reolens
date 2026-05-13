import Testing
import Foundation
@testable import AppShared

/// 0.5.1 — Per-camera notification preferences default to ON for every
/// camera. Mute state must round-trip through both the on-actor reader
/// and the nonisolated off-actor reader (which the dispatch path uses).
@MainActor
@Suite("CameraNotificationPreferences — default-on + off-actor read")
struct CameraNotificationPreferencesTests {

    private static func makeStore() -> CameraNotificationPreferences {
        UserDefaults.standard.removeObject(forKey: "com.reolens.mutedCameraNotifications")
        return CameraNotificationPreferences()
    }

    @Test("Every camera is notifying by default")
    func defaultIsNotifying() {
        let store = Self.makeStore()
        let id = UUID()
        #expect(store.isNotificationsEnabled(for: id))
        #expect(store.mutedCameras.isEmpty)
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
}

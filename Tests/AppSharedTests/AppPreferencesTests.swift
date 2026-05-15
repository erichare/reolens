import Testing
import Foundation
@testable import AppShared

/// 0.6.0 Slice 15 — `AppPreferences` is the first carve-out from the
/// 775-LOC `CameraStore` god object. Tests pin the prefs's contract:
///
/// - Round-trip persistence: a flag set on one instance shows up on a
///   fresh instance pointed at the same `UserDefaults`.
/// - Defaults to `false` for both flags (matches the existing
///   user-visible default).
/// - Test isolation: each test gets a unique `UserDefaults` suite so
///   state doesn't bleed across `@Test`s.
@MainActor
@Suite("AppPreferences")
struct AppPreferencesTests {

    /// Build a `UserDefaults` instance pinned to a unique suite name
    /// so each `@Test` runs in isolation. Mirrors the `makeFreshURL`
    /// pattern used by `NotificationHistoryTests` and the new
    /// `RecordingIndexTests`.
    private func makeFreshDefaults() -> UserDefaults {
        let suiteName = "reolens-app-prefs-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Belt-and-braces — even with a unique suite name, blow away
        // any residual entries before the test runs.
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Defaults

    @Test("Both flags default to false on a fresh install")
    func defaultsAreFalse() {
        let prefs = AppPreferences(defaults: makeFreshDefaults())
        #expect(!prefs.developerMode)
        #expect(!prefs.showCameraNameOnFeed)
    }

    // MARK: - Persistence

    @Test("Setting developerMode persists across instances")
    func developerModeRoundTrip() {
        let defaults = makeFreshDefaults()
        let writer = AppPreferences(defaults: defaults)
        writer.developerMode = true

        let reader = AppPreferences(defaults: defaults)
        #expect(reader.developerMode)
    }

    @Test("Setting showCameraNameOnFeed persists across instances")
    func cameraNameRoundTrip() {
        let defaults = makeFreshDefaults()
        let writer = AppPreferences(defaults: defaults)
        writer.showCameraNameOnFeed = true

        let reader = AppPreferences(defaults: defaults)
        #expect(reader.showCameraNameOnFeed)
    }

    @Test("Flipping a flag back to false persists as false (no key-deletion bug)")
    func flagCanBeFlippedBack() {
        let defaults = makeFreshDefaults()
        let writer = AppPreferences(defaults: defaults)
        writer.developerMode = true
        #expect(AppPreferences(defaults: defaults).developerMode)

        writer.developerMode = false
        // Fresh reader must see `false` rather than re-reading the
        // earlier `true` (which would point at a stale key).
        #expect(!AppPreferences(defaults: defaults).developerMode)
    }

    // MARK: - Isolation

    @Test("Two prefs instances with different defaults stay independent")
    func separateDefaultsAreIsolated() {
        let prefsA = AppPreferences(defaults: makeFreshDefaults())
        let prefsB = AppPreferences(defaults: makeFreshDefaults())
        prefsA.developerMode = true
        #expect(prefsA.developerMode)
        #expect(!prefsB.developerMode)
    }

    // MARK: - lastViewedCameraID

    @Test("lastViewedCameraID defaults to nil on a fresh install")
    func lastViewedCameraDefaultsToNil() {
        let prefs = AppPreferences(defaults: makeFreshDefaults())
        #expect(prefs.lastViewedCameraID == nil)
    }

    @Test("Setting lastViewedCameraID persists across instances")
    func lastViewedCameraRoundTrip() {
        let defaults = makeFreshDefaults()
        let id = UUID()
        let writer = AppPreferences(defaults: defaults)
        writer.lastViewedCameraID = id

        let reader = AppPreferences(defaults: defaults)
        #expect(reader.lastViewedCameraID == id)
    }

    @Test("Setting lastViewedCameraID to nil clears the persisted value")
    func lastViewedCameraClear() {
        let defaults = makeFreshDefaults()
        let writer = AppPreferences(defaults: defaults)
        writer.lastViewedCameraID = UUID()
        #expect(AppPreferences(defaults: defaults).lastViewedCameraID != nil)

        writer.lastViewedCameraID = nil
        #expect(AppPreferences(defaults: defaults).lastViewedCameraID == nil)
    }

    @Test("Malformed UUID string in UserDefaults decodes back to nil")
    func lastViewedCameraMalformedDecodesNil() {
        let defaults = makeFreshDefaults()
        defaults.set("not-a-uuid", forKey: AppPreferences.lastViewedCameraKey)
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.lastViewedCameraID == nil)
    }

    // MARK: - useReorganizedSettings (0.6.1)

    @Test("useReorganizedSettings defaults to true on a fresh install")
    func reorganizedSettingsDefaultsTrue() {
        let prefs = AppPreferences(defaults: makeFreshDefaults())
        #expect(prefs.useReorganizedSettings)
    }

    @Test("useReorganizedSettings respects an explicit prior false")
    func reorganizedSettingsRespectsExplicitFalse() {
        let defaults = makeFreshDefaults()
        defaults.set(false, forKey: AppPreferences.useReorganizedSettingsKey)
        let prefs = AppPreferences(defaults: defaults)
        #expect(!prefs.useReorganizedSettings)
    }

    @Test("Flipping useReorganizedSettings persists across instances")
    func reorganizedSettingsRoundTrip() {
        let defaults = makeFreshDefaults()
        let writer = AppPreferences(defaults: defaults)
        writer.useReorganizedSettings = false

        let reader = AppPreferences(defaults: defaults)
        #expect(!reader.useReorganizedSettings)
    }
}

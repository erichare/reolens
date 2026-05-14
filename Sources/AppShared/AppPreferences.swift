import Foundation
import Observation

/// 0.6.0 Slice 15 — UserDefaults-backed preferences extracted from
/// `CameraStore`.
///
/// `CameraStore` used to hold these directly, mixing UI prefs with
/// camera-list state and Keychain ops in a 775-LOC god object. This
/// type carves out the prefs slice so it can be tested in isolation
/// against a custom `UserDefaults` instance (no shared standard
/// pollution between test cases) and so future surfaces can read /
/// write prefs without depending on the whole CameraStore.
///
/// CameraStore embeds one of these and proxies its existing public
/// properties to the embedded instance — keeping the API stable so
/// the hundreds of callers across the app don't need to change.
@MainActor
@Observable
public final class AppPreferences {

    /// Storage backend. Injected so tests can use a `UserDefaults`
    /// pinned to a unique suite name per test.
    @ObservationIgnored
    private let defaults: UserDefaults

    /// Developer mode. Surfaces diagnostic UI (Raw JSON popovers,
    /// verbose log buttons, etc.) that would otherwise clutter the
    /// default view.
    public var developerMode: Bool {
        didSet {
            defaults.set(developerMode, forKey: Self.developerModeKey)
        }
    }

    /// Global "Show camera name on feed" preference. Default OFF
    /// because Reolink cameras typically burn their own OSD into the
    /// top-left of the frame; the app badge collides with it.
    public var showCameraNameOnFeed: Bool {
        didSet {
            defaults.set(showCameraNameOnFeed, forKey: Self.showCameraNameKey)
        }
    }

    /// 0.6.0 — iOS / iPadOS "restore last camera on launch" memory.
    /// Set by the platform shell whenever the user navigates into a
    /// camera detail view; read on first appear to push that camera
    /// back onto the navigation stack so returning users don't re-
    /// pick the camera they were last viewing.
    ///
    /// Storage stays in UserDefaults (per-device) on purpose: every
    /// Apple device has a different "last camera I was watching" —
    /// the iPhone landing on the iPad's last selection would surprise
    /// users. macOS doesn't read this today because the macOS sidebar
    /// already preserves selection across launches via its own
    /// state-restoration plumbing.
    public var lastViewedCameraID: UUID? {
        didSet {
            if let id = lastViewedCameraID {
                defaults.set(id.uuidString, forKey: Self.lastViewedCameraKey)
            } else {
                defaults.removeObject(forKey: Self.lastViewedCameraKey)
            }
        }
    }

    /// 0.6.1 — opt-in to the redesigned Settings IA. Defaults to
    /// `true` in DEBUG so the new IA is exercised during simulator /
    /// macOS click-through; release builds get the new IA too — the
    /// flag exists primarily as an emergency revert, not a long-term
    /// rollout gate. Remove the legacy path in 0.7.x once we've
    /// confirmed no regressions in the wild.
    public var useReorganizedSettings: Bool {
        didSet {
            defaults.set(useReorganizedSettings, forKey: Self.useReorganizedSettingsKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.developerMode = defaults.bool(forKey: Self.developerModeKey)
        self.showCameraNameOnFeed = defaults.bool(forKey: Self.showCameraNameKey)
        self.lastViewedCameraID = defaults.string(forKey: Self.lastViewedCameraKey)
            .flatMap(UUID.init(uuidString:))
        // The reorganized Settings IA defaults ON when the user has
        // never touched the flag — so a fresh install gets the new
        // structure. Existing users keep whatever they last set.
        if defaults.object(forKey: Self.useReorganizedSettingsKey) == nil {
            self.useReorganizedSettings = true
            defaults.set(true, forKey: Self.useReorganizedSettingsKey)
        } else {
            self.useReorganizedSettings = defaults.bool(forKey: Self.useReorganizedSettingsKey)
        }
    }

    // MARK: - Keys

    static let developerModeKey = "com.reolens.developerMode"
    static let showCameraNameKey = "com.reolens.showCameraNameOnFeed"
    static let lastViewedCameraKey = "com.reolens.lastViewedCameraID"
    static let useReorganizedSettingsKey = "com.reolens.useReorganizedSettings"

    // MARK: - Non-isolated peeks

    /// Read the developer-mode flag from outside the MainActor.
    /// Background logging hooks (`CameraSession` polling continuations,
    /// CloudKit subscriber observers) call this to decide whether to
    /// emit `.debug` log lines without hopping actors. Reads from
    /// `.standard` because that's where the live `CameraStore` —
    /// constructed without a custom `defaults` argument — writes.
    public static var developerModeIsOn: Bool {
        UserDefaults.standard.bool(forKey: developerModeKey)
    }
}

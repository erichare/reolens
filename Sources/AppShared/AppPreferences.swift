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

    /// Default quality for tap-to-play across both per-camera and
    /// All Recordings lists. The player sheet still exposes a toggle
    /// so the user can override per-clip; this is just the seed
    /// value. Defaults to `.low` because sub-stream first-frame
    /// latency on LAN is dramatically faster than main-stream and
    /// most users open recordings to triage motion events rather
    /// than to evaluate detail.
    public var defaultRecordingQuality: RecordingQuality {
        didSet {
            defaults.set(defaultRecordingQuality.rawValue, forKey: Self.defaultRecordingQualityKey)
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.developerMode = defaults.bool(forKey: Self.developerModeKey)
        self.showCameraNameOnFeed = defaults.bool(forKey: Self.showCameraNameKey)
        self.defaultRecordingQuality = (defaults.string(forKey: Self.defaultRecordingQualityKey)
            .flatMap(RecordingQuality.init(rawValue:))) ?? .low
        self.lastViewedCameraID = defaults.string(forKey: Self.lastViewedCameraKey)
            .flatMap(UUID.init(uuidString:))
    }

    // MARK: - Keys

    static let developerModeKey = "com.reolens.developerMode"
    static let showCameraNameKey = "com.reolens.showCameraNameOnFeed"
    static let defaultRecordingQualityKey = "com.reolens.defaultRecordingQuality"
    static let lastViewedCameraKey = "com.reolens.lastViewedCameraID"

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

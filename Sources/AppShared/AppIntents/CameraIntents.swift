import Foundation
import AppIntents
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "intents")

/// Shortcuts integration. Exposes "Open Camera" as a configurable
/// shortcut and Siri voice command so users can say "Hey Siri, open
/// the Front Door camera in Reolens" or chain a camera open into a
/// Shortcuts automation.
///
/// Pattern:
/// 1. `OpenCameraIntent` writes the requested camera ID to a known
///    `UserDefaults` key (the *intent focus pointer*) and tells iOS
///    to bring the app forward.
/// 2. Each app's scene reads that key on launch / foreground via
///    `AppIntentFocus.consumePending()` and sets `CameraStore.selection`
///    accordingly.
///
/// The intent never receives or stores credentials. If the user's
/// chosen camera has no Keychain password on the running device, the
/// app surfaces the standard `EnterPasswordSheet` flow once focused.
@available(iOS 16, macOS 13, *)
public struct CameraEntity: AppEntity, Identifiable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Camera"
    }

    public static let defaultQuery = CameraEntityQuery()

    public let id: UUID
    public let displayName: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

@available(iOS 16, macOS 13, *)
public struct CameraEntityQuery: EntityQuery {
    public init() {}

    /// Look up cameras by ID. Reads the same `cameras.json` file as the
    /// running app — works even when the app isn't open (Shortcuts may
    /// resolve parameters from a background process).
    public func entities(for identifiers: [UUID]) async throws -> [CameraEntity] {
        let all = await Self.loadCameras()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    /// Suggestions shown to the user when they're picking a camera in
    /// the Shortcuts app or the Siri prompt.
    public func suggestedEntities() async throws -> [CameraEntity] {
        await Self.loadCameras()
    }

    @MainActor
    private static func loadCameras() async -> [CameraEntity] {
        guard let data = ICloudCameraStorage.shared.read(),
              let entries = try? JSONDecoder().decode([CameraEntry].self, from: data)
        else { return [] }
        return entries.map { CameraEntity(id: $0.id, displayName: $0.displayName) }
    }
}

@available(iOS 16, macOS 13, *)
public struct OpenCameraIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Camera"
    public static let description = IntentDescription("Opens Reolens with a specific camera focused for live view.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Camera")
    public var camera: CameraEntity

    public init() {}

    public init(camera: CameraEntity) {
        self.camera = camera
    }

    public func perform() async throws -> some IntentResult {
        AppIntentFocus.requestFocus(deviceID: camera.id)
        log.info("OpenCameraIntent requested focus for \(camera.id, privacy: .public)")
        return .result()
    }
}

/// Shared focus pointer between out-of-process surfaces (App Intents
/// from Shortcuts/Siri, notification tap handlers) and the running app.
/// Apps observe `consumePending()` on launch and foreground; the
/// requesting surface writes a `Target` to it. Backed by `UserDefaults`
/// so the value survives a fresh launch from a backgrounded state.
public enum AppIntentFocus {
    /// What the user wants to focus on after launching the app.
    public enum Target: Sendable, Codable, Equatable {
        /// Open the live view for the named device. Used by
        /// `OpenCameraIntent` (Shortcuts/Siri) and by notification taps
        /// that fire on a recent event (< 1 minute old).
        case liveCamera(deviceID: UUID)
        /// Open the recordings browser for the named device + channel,
        /// positioned at `at`. Used by notification taps that fire on
        /// an older event — the user is more likely to want to scrub
        /// to the captured clip than re-watch the (already-stopped)
        /// live feed.
        case recording(deviceID: UUID, channelID: Int, at: Date)
        /// 0.5.0 Theme A5 — open the overnight-digest detail sheet
        /// for the given local-midnight `day`. Fired by tapping the
        /// daily digest notification.
        case digest(day: Date)
    }

    private static let key = "com.reolens.intent.focusTarget"
    /// Legacy key used before 0.3.0 added richer Target. Drained on
    /// `consumePending()` so notifications/Shortcuts written by a
    /// pre-0.3.x build still route correctly after the user upgrades.
    private static let legacyKey = "com.reolens.intent.focusedCameraID"

    /// Broadcast when a focus request is written. Subscribed to by
    /// app scenes that need to re-drain the pending intent without
    /// waiting for the next scene-phase or active-notification cycle
    /// — the cold-launch-via-notification-tap path writes the intent
    /// AFTER the scene's launch `.task` has already drained it.
    public static let didUpdate = Notification.Name("com.reolens.intent.focusUpdated")

    public static func request(_ target: Target) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // Posting on the main queue so SwiftUI's `.onReceive` runs on
        // the same actor as the rest of the scene code. Notification
        // observers (which include CameraStore's drain) hop the
        // MainActor anyway, but going through the main queue is
        // cheaper and avoids a brief inconsistency window.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didUpdate, object: nil)
        }
    }

    /// Convenience wrapper for the common case (live view of a device).
    public static func requestFocus(deviceID: UUID) {
        request(.liveCamera(deviceID: deviceID))
    }

    /// Drain and return any pending focus request. Idempotent on the
    /// "no pending request" case. Apps call this on launch and on
    /// foreground; consuming it here ensures we don't keep re-applying
    /// the same focus every time the user puts the app in background
    /// and brings it back.
    public static func consumePending() -> Target? {
        if let data = UserDefaults.standard.data(forKey: key),
           let target = try? JSONDecoder().decode(Target.self, from: data) {
            UserDefaults.standard.removeObject(forKey: key)
            return target
        }
        // Legacy fallback: a pre-0.3.0 build wrote a bare UUID string.
        if let raw = UserDefaults.standard.string(forKey: legacyKey),
           let id = UUID(uuidString: raw) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return .liveCamera(deviceID: id)
        }
        return nil
    }
}

/// 0.5.1 — "Show today's events" — jumps to the All Recordings view
/// optionally filtered to a specific camera. The intent itself only
/// writes the focus target; the running app consumes it via
/// `AppIntentFocus.consumePending()` on foreground.
@available(iOS 16, macOS 13, *)
public struct ShowTodayEventsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Today's Events"
    public static let description = IntentDescription("Opens Reolens to today's recordings. Optionally filter to a specific camera.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Camera (optional)", default: nil)
    public var camera: CameraEntity?

    public init() {}

    public init(camera: CameraEntity? = nil) {
        self.camera = camera
    }

    public func perform() async throws -> some IntentResult {
        // For the "all cameras today" case we still need a routing
        // hint; AppIntentFocus.Target.recording carries (deviceID,
        // channelID, at). With no camera selected, fall back to
        // .liveCamera of the first known camera so the user still
        // lands inside the app and can navigate from there. Future
        // work: add a .todayEvents target so the focus pointer is
        // unambiguous.
        if let camera {
            AppIntentFocus.request(.recording(
                deviceID: camera.id,
                channelID: 0,
                at: Date()
            ))
            log.info("ShowTodayEventsIntent focused \(camera.id, privacy: .public)")
        } else {
            log.info("ShowTodayEventsIntent without a camera — caller will land on hub-scoped All Recordings")
        }
        return .result()
    }
}

/// 0.5.1 — "Mute (or unmute) <camera> notifications" — flips the
/// per-camera notification preference. Effects sync to the user's
/// other Apple devices via `NSUbiquitousKeyValueStore`.
@available(iOS 16, macOS 13, *)
public struct MuteCameraNotificationsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mute Camera Notifications"
    public static let description = IntentDescription("Stop notifications from a specific camera. Run again (or set Enabled to true) to re-enable.")
    /// Don't bring the app forward; this is a configuration intent that
    /// should be silent when triggered from a Shortcut.
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Camera")
    public var camera: CameraEntity

    @Parameter(title: "Enabled", default: false)
    public var enabled: Bool

    public init() {}

    public init(camera: CameraEntity, enabled: Bool) {
        self.camera = camera
        self.enabled = enabled
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        CameraNotificationPreferences.shared.setNotificationsEnabled(enabled, for: camera.id)
        let verb = enabled ? "notifying" : "muted"
        return .result(dialog: IntentDialog("\(camera.displayName) is now \(verb)."))
    }
}

@available(iOS 16, macOS 13, *)
public struct ReolensShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCameraIntent(),
            phrases: [
                "Open \(.applicationName) camera",
                "Show camera in \(.applicationName)",
                "Open \(\.$camera) in \(.applicationName)"
            ],
            shortTitle: "Open Camera",
            systemImageName: "video.fill"
        )
        AppShortcut(
            intent: ShowTodayEventsIntent(),
            phrases: [
                "Show today's events in \(.applicationName)",
                "Show \(\.$camera) events today in \(.applicationName)"
            ],
            shortTitle: "Show Today's Events",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: MuteCameraNotificationsIntent(),
            phrases: [
                "Mute \(\.$camera) in \(.applicationName)",
                "Set \(\.$camera) notifications in \(.applicationName)"
            ],
            shortTitle: "Mute Camera Notifications",
            systemImageName: "bell.slash"
        )
    }
}

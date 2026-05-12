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

/// Shared focus pointer between the App Intents extension surface and
/// the running app. Apps observe `pendingDeviceID` on launch and
/// foreground; the intent writes to it. Backed by `UserDefaults` so the
/// value survives a fresh launch from the Shortcuts app.
public enum AppIntentFocus {
    private static let key = "com.reolens.intent.focusedCameraID"

    public static func requestFocus(deviceID: UUID) {
        UserDefaults.standard.set(deviceID.uuidString, forKey: key)
    }

    /// Drain and return any pending focus request. Idempotent on the
    /// "no pending request" case. Apps call this on launch and on
    /// foreground; consuming it here ensures we don't keep re-applying
    /// the same focus every time the user puts the app in background
    /// and brings it back.
    public static func consumePending() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let id = UUID(uuidString: raw)
        else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return id
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
    }
}

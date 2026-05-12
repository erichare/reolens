import Foundation
import Observation
import UserNotifications
import OSLog
import ReolinkAPI
import ReolinkBaichuan

#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "notifier")

/// macOS user-notification gateway for Reolink AI/motion events.
///
/// Every `BaichuanEvent` that arrives via the live alarm subscription on
/// any active `CameraSession` is funneled through `notify(...)`. The
/// service:
///
///   1. Honors a user-toggleable "enabled" preference plus the OS
///      authorization state (we never show a notification the user hasn't
///      consented to).
///   2. Throttles per `(channel, kind)` pair on a 30 s cooldown so a
///      sustained motion event doesn't fire dozens of identical
///      notifications.
///   3. Downloads a fresh still from the camera's `cmd=Snap` endpoint and
///      attaches it to the notification — `UNNotificationAttachment` is
///      what gives Apple's Notification Center the "rich" preview with a
///      thumbnail (and the expanded view shown when the user hovers).
///
/// Lives as a `@MainActor`-isolated singleton because everything it
/// touches (`UNUserNotificationCenter`, `@Observable` UI state, the
/// SwiftUI settings view) is main-thread anyway. Singleton because
/// notifications are a shared OS resource — no benefit to per-device
/// instances.
@MainActor
@Observable
public final class EventNotifier {
    public static let shared = EventNotifier()

    /// User preference, persisted in `UserDefaults`. When false, no
    /// notifications are posted regardless of permission state.
    public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// True when the user has explicitly opted in to AI-triggered
    /// notifications (person, vehicle, pet, …). Defaults on.
    public var notifyAI: Bool {
        didSet { UserDefaults.standard.set(notifyAI, forKey: Self.aiKey) }
    }

    /// True when plain motion events (no AI classification) also fire
    /// notifications. Defaults off — motion-only events tend to flood
    /// when sustained.
    public var notifyMotion: Bool {
        didSet { UserDefaults.standard.set(notifyMotion, forKey: Self.motionKey) }
    }

    /// Current OS authorization state. Updated on app launch and after
    /// every `requestPermission(...)` call.
    public private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

    private static let enabledKey = "com.reolens.notifications.enabled"
    private static let aiKey = "com.reolens.notifications.ai"
    private static let motionKey = "com.reolens.notifications.motion"
    private static let cooldown: TimeInterval = 30

    /// Per-(channel, kind) timestamp of the last delivered notification.
    /// Used to throttle sustained alarm streams.
    private var lastNotifiedAt: [String: Date] = [:]

    private init() {
        // Default `enabled` to true; the OS permission state is what
        // ultimately gates delivery, so flipping this on by default just
        // means "ready as soon as the user grants permission".
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.aiKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.aiKey)
        }
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.notifyAI = UserDefaults.standard.bool(forKey: Self.aiKey)
        self.notifyMotion = UserDefaults.standard.bool(forKey: Self.motionKey)
        Task { await refreshPermissionStatus() }
    }

    // MARK: - Permission

    /// Re-read the OS authorization state. Cheap; call after returning
    /// from System Settings or after `requestPermission(...)`.
    ///
    /// Uses the callback-style API instead of the `async` overload so we
    /// only pull the `UNAuthorizationStatus` (Sendable enum) across the
    /// actor boundary, not the entire `UNNotificationSettings` object
    /// (which is non-Sendable and trips Swift 6's strict-concurrency
    /// checker when crossing into the MainActor-isolated caller).
    ///
    /// **Why the explicit `@Sendable` typed handler.** Without the
    /// explicit type, Swift 6.2's "approachable concurrency" infers the
    /// completion-handler closure as inheriting the caller's isolation
    /// — `@MainActor` here, since this method is `@MainActor`. But
    /// `UNUserNotificationCenter` actually invokes the callback on its
    /// own private serial queue (`com.apple.usernotifications.UNUser
    /// NotificationServiceConnection.call-out`). When the closure body
    /// runs on that queue, the runtime's actor-isolation check
    /// (`swift_task_isCurrentExecutorWithFlags`) fires SIGTRAP and the
    /// app crashes on launch. Declaring the handler as
    /// `@Sendable (UNNotificationSettings) -> Void` opts out of caller
    /// isolation; UN can call us back on any queue and we just hop the
    /// captured `CheckedContinuation` back to the awaiting MainActor
    /// (which is what `cont.resume` does internally).
    public func refreshPermissionStatus() async {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<UNAuthorizationStatus, Never>) in
            let handler: @Sendable (UNNotificationSettings) -> Void = { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
            UNUserNotificationCenter.current().getNotificationSettings(completionHandler: handler)
        }
        self.permissionStatus = status
    }

    /// Prompt the user for notification permission. Idempotent — if
    /// already granted, just returns true; if previously denied, returns
    /// false and tells the caller to send the user to System Settings.
    @discardableResult
    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshPermissionStatus()
        return granted
    }

    /// Open System Settings → Notifications focused on this app, so the
    /// user can flip the OS-level permission when our `requestPermission`
    /// gets a previously-denied no-op.
    public func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            Task { @MainActor in
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
            }
        }
        #endif
    }

    // MARK: - Posting

    /// Post a notification for the given alarm event, after applying the
    /// enabled / permission / throttle / per-kind preference gates.
    /// `snapshotURL` is the Reolink `cmd=Snap` URL; if non-nil and the
    /// download succeeds, the JPEG becomes a rich attachment in the
    /// notification.
    public func notify(
        event: BaichuanEvent,
        cameraName: String,
        snapshotURL: URL?
    ) async {
        guard enabled, permissionStatus == .authorized else { return }

        let (title, body, throttleKey) = format(event: event, cameraName: cameraName)
        guard !title.isEmpty else { return }

        if let last = lastNotifiedAt[throttleKey],
           Date().timeIntervalSince(last) < Self.cooldown {
            return
        }
        lastNotifiedAt[throttleKey] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "ch-\(event.channelID)"
        content.categoryIdentifier = "reolens.alarm"

        // Best-effort rich-notification attachment. We don't await the
        // download for too long — a Reolink snap typically arrives in
        // under a second, and the user shouldn't have a notification
        // delayed by a slow camera. If we can't get the JPEG, we still
        // post the notification with just the text.
        if let snapshotURL,
           let attachment = await downloadSnapshotAttachment(from: snapshotURL) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        // Use the callback API rather than the `async` overload for the
        // same reason as `refreshPermissionStatus`: `UNNotificationRequest`
        // is non-Sendable and the `async` overload's parameter crossing
        // the MainActor → nonisolated boundary trips Swift 6's
        // strict-concurrency checker. The callback fires on the
        // notification queue, never inspects the request from another
        // isolation context, and just hands us back an optional error.
        // `(any Error)?` because the target uses `ExistentialAny`.
        //
        // The handler is explicitly typed `@Sendable` so Swift 6.2
        // doesn't infer it as inheriting `@MainActor` — see the long
        // comment on `refreshPermissionStatus` for what goes wrong when
        // it does.
        let postError: (any Error)? = await withCheckedContinuation { (cont: CheckedContinuation<(any Error)?, Never>) in
            let handler: @Sendable ((any Error)?) -> Void = { error in
                cont.resume(returning: error)
            }
            UNUserNotificationCenter.current().add(request, withCompletionHandler: handler)
        }
        if let postError {
            log.warning("Couldn't post notification: \(postError.localizedDescription, privacy: .public)")
        } else {
            log.info("Notified: \(title, privacy: .public) — \(body, privacy: .public)")
        }
    }

    /// Build the title/body for an event, plus a stable key for the
    /// throttle map. `nil`-keyed events return an empty triple so the
    /// caller can drop them.
    private func format(event: BaichuanEvent, cameraName: String) -> (title: String, body: String, throttleKey: String) {
        switch event.kind {
        case .ai(let tag):
            guard notifyAI else { return ("", "", "") }
            let detection = DetectionType.fromReolinkString(tag)
            let label = detection?.label ?? tag.capitalized
            return ("\(label) detected", cameraName, "\(event.channelID)-ai-\(tag)")
        case .motionStart:
            guard notifyMotion else { return ("", "", "") }
            return ("Motion detected", cameraName, "\(event.channelID)-motion")
        case .motionStop, .other:
            return ("", "", "")
        }
    }

    /// Download the snapshot JPEG to a temp file and wrap it in a
    /// `UNNotificationAttachment`. AppKit auto-moves the file into its
    /// own storage on `add(request:)`, so we don't need to keep the temp
    /// path around afterward.
    private func downloadSnapshotAttachment(from url: URL) async -> UNNotificationAttachment? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                log.warning("Snap returned HTTP \(http.statusCode); skipping attachment")
                return nil
            }
            // UNNotificationAttachment requires the file to exist at the
            // referenced URL with a recognized extension. Save the JPEG to
            // a uniquely-named file under the temp directory.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("reolens-snap-\(UUID().uuidString).jpg")
            try data.write(to: dest)
            return try UNNotificationAttachment(
                identifier: dest.lastPathComponent,
                url: dest,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
            )
        } catch {
            log.warning("Snapshot download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

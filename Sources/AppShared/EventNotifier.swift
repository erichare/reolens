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

    /// Master toggle for AI-triggered notifications. When off, no
    /// AI-classified event fires regardless of per-tag preferences below.
    /// Defaults on.
    public var notifyAI: Bool {
        didSet { UserDefaults.standard.set(notifyAI, forKey: Self.aiKey) }
    }

    /// True when plain motion events (no AI classification) also fire
    /// notifications. Defaults off — motion-only events tend to flood
    /// when sustained.
    public var notifyMotion: Bool {
        didSet { UserDefaults.standard.set(notifyMotion, forKey: Self.motionKey) }
    }

    /// Per-AI-tag notification preferences (added in 0.4.0). Lets the
    /// user keep "person" alerts on while muting frequent "pet" ones,
    /// etc. Reading these as a dictionary so the format/filter loop
    /// can do a single lookup per event. All default true so opted-in
    /// AI notifications behave as in 0.3.0 unless the user customizes.
    public var notifyPerTag: [DetectionType: Bool] {
        didSet {
            for (tag, on) in notifyPerTag {
                UserDefaults.standard.set(on, forKey: Self.perTagKey(tag))
            }
        }
    }

    /// Current OS authorization state. Updated on app launch and after
    /// every `requestPermission(...)` call.
    public private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

    private static let enabledKey = "com.reolens.notifications.enabled"
    private static let aiKey = "com.reolens.notifications.ai"
    private static let motionKey = "com.reolens.notifications.motion"
    private static func perTagKey(_ tag: DetectionType) -> String {
        "com.reolens.notifications.tag.\(tag.rawValue)"
    }
    private static let cooldown: TimeInterval = 30

    // userInfo dictionary keys used to carry the routing payload from a
    // posted notification back into the app on tap. Public so the
    // delegate in the same module can reference them by symbol rather
    // than retyping the string. `nonisolated` because they're plain
    // immutable strings — the delegate that reads them runs off the
    // main actor in the system notification callback.
    nonisolated public static let userInfoCameraIDKey = "cameraID"
    nonisolated public static let userInfoChannelKey = "channelID"
    nonisolated public static let userInfoEventTimeKey = "eventTime"

    /// Notification freshness threshold for routing taps. Taps on an
    /// event posted within this window go to the camera's live view;
    /// older taps go to the recording browser, where the captured clip
    /// is more useful than the (already-stopped) live feed.
    nonisolated static let liveTapThreshold: TimeInterval = 60

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
        // Load per-tag preferences. Missing keys (i.e. users upgrading
        // from 0.3.0 where these didn't exist) default to true so
        // existing AI notifications keep firing exactly as before.
        var loaded: [DetectionType: Bool] = [:]
        for tag in DetectionType.allCases where tag != .motion {
            let key = Self.perTagKey(tag)
            let stored = UserDefaults.standard.object(forKey: key) as? Bool
            loaded[tag] = stored ?? true
        }
        self.notifyPerTag = loaded
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
        cameraID: UUID,
        cameraName: String,
        snapshotURL: URL?
    ) async {
        // Relay to the user's other Apple devices via CloudKit IF
        // the user has opted in (macOS only; on iOS the publisher
        // setting is irrelevant because the iOS app receives, it
        // doesn't publish). This runs OUTSIDE the local-notification
        // gates so an opted-in macOS Reolens still publishes events
        // even when local notifications are muted on that machine —
        // the user might have muted on the Mac specifically because
        // they want the alerts on iPhone.
        #if os(macOS)
        if MotionEventRelaySettings.publisherEnabled {
            await relayToCloudKit(event: event, cameraID: cameraID, snapshotURL: snapshotURL)
        }
        #endif
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
        // userInfo lets the tap handler route to live view (when fresh)
        // or the recording browser (when older). Stored as primitives —
        // UNUserNotificationCenter requires the dictionary to be plist-
        // serializable. See `EventNotifierDelegate` for the read side.
        content.userInfo = [
            Self.userInfoCameraIDKey: cameraID.uuidString,
            Self.userInfoChannelKey: Int(event.channelID),
            Self.userInfoEventTimeKey: Date().timeIntervalSince1970,
        ]

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
    /// macOS-only CloudKit relay hook. Downloads the snapshot once,
    /// stages it as a `CKAsset`, publishes the record via the shared
    /// publisher. Errors are logged but never user-visible — relay
    /// is opportunistic; the local notification is the source of
    /// truth.
    #if os(macOS)
    private func relayToCloudKit(event: BaichuanEvent, cameraID: UUID, snapshotURL: URL?) async {
        // Stage the snapshot as a local temp file so we can hand it
        // to CKAsset by URL. (`CKAsset` requires a fileURL on disk
        // at upload time.) Best-effort — events without a snapshot
        // still relay; the iOS subscriber renders the text.
        var stagedSnapshot: URL?
        if let snapshotURL,
           let attachment = await downloadSnapshotAttachment(from: snapshotURL) {
            stagedSnapshot = attachment.url
        }
        let detection: String
        switch event.kind {
        case .ai(let tag): detection = tag
        case .motionStart: detection = "motion"
        case .motionStop, .other: return
        }
        let payload = MotionEvent(
            cameraID: cameraID,
            channel: Int(event.channelID),
            detection: detection,
            timestamp: Date(),
            snapshotFileURL: stagedSnapshot
        )
        let publisher = CloudKitMotionEventPublisher()
        await publisher.publish(payload)
    }
    #endif

    /// caller can drop them.
    private func format(event: BaichuanEvent, cameraName: String) -> (title: String, body: String, throttleKey: String) {
        switch event.kind {
        case .ai(let tag):
            guard notifyAI else { return ("", "", "") }
            let detection = DetectionType.fromReolinkString(tag)
            // Per-tag filter (0.4.0). When the detection maps to a
            // known DetectionType, honor the user's per-tag toggle.
            // Unknown tags fall through with the master `notifyAI`
            // gate above so the firmware can roll out new categories
            // without us silently dropping them.
            if let detection, notifyPerTag[detection] == false {
                return ("", "", "")
            }
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

/// `UNUserNotificationCenterDelegate` that translates notification taps
/// into `AppIntentFocus` requests. Install via `installNotificationTapHandler()`
/// from each app's scene on launch.
///
/// Routing rule: if the user taps within `EventNotifier.liveTapThreshold`
/// seconds of the event, the camera's live view opens (the action is
/// likely still happening). After that window, the recording browser
/// opens instead — the live feed has nothing actionable in it.
public final class NotificationTapDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationTapDelegate()

    /// Install this delegate as the user-notification center's delegate.
    /// Call from each app's scene `task` on launch. Safe to call more
    /// than once — `UNUserNotificationCenter.delegate` accepts a single
    /// assignment and replays harmlessly.
    @MainActor
    public static func install() {
        UNUserNotificationCenter.current().delegate = NotificationTapDelegate.shared
    }

    /// Show the banner even when the app is foregrounded — otherwise
    /// motion alerts that fire while the user is looking at one camera
    /// would silently disappear.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// User tapped a notification (or its default action). Translate
    /// the payload into an `AppIntentFocus` target. The running app's
    /// `applyPendingIntentFocus()` (already invoked on foreground)
    /// will pick this up and route.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        defer { completionHandler() }
        guard
            let cameraString = userInfo[EventNotifier.userInfoCameraIDKey] as? String,
            let cameraID = UUID(uuidString: cameraString)
        else { return }
        let channelID = (userInfo[EventNotifier.userInfoChannelKey] as? Int) ?? 0
        let eventTime = (userInfo[EventNotifier.userInfoEventTimeKey] as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) }
            ?? Date()
        let age = Date().timeIntervalSince(eventTime)
        let target: AppIntentFocus.Target
        if age < EventNotifier.liveTapThreshold {
            target = .liveCamera(deviceID: cameraID)
        } else {
            target = .recording(deviceID: cameraID, channelID: channelID, at: eventTime)
        }
        AppIntentFocus.request(target)
        // The running app's foreground/launch task drains the pointer
        // and routes. We also kick a Darwin notification post here to
        // help wake the app if it was suspended — but the standard
        // delegate flow already foregrounds for `didReceive`, so this
        // is belt-and-suspenders.
    }
}


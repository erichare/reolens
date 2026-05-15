import Foundation
import Observation
import UserNotifications
import OSLog
import ReolinkAPI
import ReolinkBaichuan
#if canImport(WidgetKit)
import WidgetKit
#endif

#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "notifier")

/// 0.5.0 — protocol-typed bridge from `EventNotifier` (AppShared) to
/// the iOS-only `MotionEventActivityController` (AppiOS). Keeps the
/// AppShared library free of `ActivityKit` imports while still letting
/// motion events drive Live Activity start/update/end on iOS.
///
/// The iOS app registers a concrete implementation at launch:
///
/// ```swift
/// // ReolensiOSApp.init():
/// EventNotifier.liveActivityBridge = MotionEventActivityBridge()
/// ```
public protocol MotionEventLiveActivityBridge: Sendable {
    func start(
        cameraID: UUID,
        channel: Int,
        cameraName: String,
        aiTags: [String],
        triggerFrameJPEG: Data?
    ) async
}

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
    /// Same throttle, but for the macOS CloudKit relay path. Relay is
    /// deliberately independent from local notification authorization,
    /// yet it must not download a snapshot for every repeated push in a
    /// motion burst.
    private var lastRelayedAt: [String: Date] = [:]

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
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // 0.6.1 — distinguish a thrown error from a user-denied
            // false. Previously both collapsed into `granted = false`,
            // making the difference between "user said no" and
            // "system request errored" invisible from the UI.
            // 0.6.1 H-1/M-1 follow-up — route to the typed
            // `permissionDenied` case (semantically correct for this
            // local UN call) rather than `publishFailed`, which is
            // documented as an iCloud-relay failure.
            AppErrorRecorder.recordAsync(
                .notification(.permissionDenied),
                context: "eventNotifier.requestPermission"
            )
            granted = false
        }
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
        let classification = classify(event: event, cameraName: cameraName)

        // Non-notifiable kinds (motion-stop, other) never reach the
        // user log — they aren't user-visible events to begin with.
        if case .ignored = classification {
            return
        }

        // Suppressed-but-loggable kinds: the user has muted the
        // category. Record so they can see it in the notification log
        // and understand WHY a real event didn't surface.
        if case .suppressedForLog(let syntheticTitle, let tag, let reason) = classification {
            await logDroppedEvent(
                event: event,
                cameraID: cameraID,
                cameraName: cameraName,
                title: syntheticTitle,
                tag: tag,
                reason: reason
            )
            return
        }

        guard case .composed(let title, let body, let throttleKey, let tag) = classification else {
            return
        }

        // 0.5.1 — per-camera notification toggle (defaults to ON,
        // synced across devices via NSUbiquitousKeyValueStore). The
        // off-main-actor read avoids hopping the MainActor for every
        // alarm event on a busy hub.
        guard CameraNotificationPreferences.isNotificationsEnabledOffMainActor(for: cameraID) else {
            await logDroppedEvent(
                event: event,
                cameraID: cameraID,
                cameraName: cameraName,
                title: title,
                tag: tag,
                reason: .perCameraMuted
            )
            return
        }

        let relayAllowed: Bool
        #if os(macOS)
        // Relay to the user's other Apple devices via CloudKit IF
        // the user has opted in. This stays outside the local
        // notification authorization gates so an opted-in Mac can
        // still publish events when local banners are muted, but it
        // now shares the same burst throttle. Before this, a single
        // sustained event could spawn dozens of snapshot downloads,
        // saturating the hub and making foreground Search/RTSP feel
        // painfully slow.
        relayAllowed = MotionEventRelaySettings.publisherEnabled
            && consumeRelayCooldown(for: throttleKey)
        #else
        relayAllowed = false
        #endif

        // 0.6.0 — split the three gates apart so the notification log
        // can record the specific failure reason. The combined boolean
        // still drives the post-or-skip decision.
        let masterEnabled = enabled
        let permissionGranted = permissionStatus == .authorized
        let throttleOK = consumeLocalNotificationCooldown(for: throttleKey)
        let localNotificationAllowed = masterEnabled && permissionGranted && throttleOK

        guard relayAllowed || localNotificationAllowed else {
            let reason: NotificationRecord.DeliveryStatus
            if !masterEnabled {
                reason = .globallyDisabled
            } else if !permissionGranted {
                reason = .permissionDenied
            } else {
                reason = .throttledCooldown
            }
            await logDroppedEvent(
                event: event,
                cameraID: cameraID,
                cameraName: cameraName,
                title: title,
                tag: tag,
                reason: reason
            )
            return
        }

        // Download once and reuse the temp file for both CloudKit relay
        // and the local notification. Reolink snapshot requests are
        // expensive on busy hubs; doing this before throttle checks was
        // the source of the macOS timeout storm seen in unified logs.
        let attachment: UNNotificationAttachment?
        if let snapshotURL {
            attachment = await downloadSnapshotAttachment(from: snapshotURL)
        } else {
            attachment = nil
        }

        #if os(macOS)
        if relayAllowed {
            await relayToCloudKit(
                event: event,
                cameraID: cameraID,
                snapshotFileURL: attachment?.url
            )
        }
        #endif

        guard localNotificationAllowed else { return }

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
        if let attachment {
            content.attachments = [attachment]
        }

        // Allocate the UUID once so the same id flows into the
        // notification request and into the notification log — that
        // way `NotificationTapDelegate` can mark the right record as
        // tapped when the user opens it.
        let notificationID = UUID()
        let request = UNNotificationRequest(
            identifier: notificationID.uuidString,
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

        // 0.6.0 — record into the user-facing notification log so the
        // user can browse delivered notifications + filter by camera,
        // tag, or status. Failures get logged with `.failed` so a
        // permission-state-versus-add-failed split is visible.
        let postedRecord = NotificationRecord(
            id: notificationID,
            timestamp: Date(),
            source: .local,
            cameraID: cameraID,
            channel: Int(event.channelID),
            cameraName: cameraName,
            detectionTag: tag,
            title: title,
            body: body,
            thumbnailRelativePath: nil,
            deliveryStatus: postError == nil ? .posted : .failed
        )
        Task { await NotificationHistory.shared.record(postedRecord) }

        // 0.5.0 — record the event into the shared App Group so
        // widgets (CameraSnapshotWidget, LastMotionWidget,
        // MotionDigestWidget) can render the most-recent fire
        // without re-querying the camera. Also bumps the
        // `lastMotionAt` on the per-camera snapshot record so the
        // snapshot widget's "fired 4m ago" relative timestamp stays
        // fresh.
        Self.publishToWidgetContainer(
            event: event,
            cameraID: cameraID,
            cameraName: cameraName,
            snapshotURL: attachment?.url
        )

        // 0.6.0 — refresh the per-camera health badge driver after
        // every published notification so the sidebar tag flips to
        // "now" immediately. EventNotifier is @MainActor, so we're
        // already on the right isolation domain for the @Observable
        // refresh.
        CameraNotificationHealth.shared.refresh()

        #if os(iOS)
        // Start (or replace) the in-flight motion-event Live Activity
        // on iOS. Activities are short-lived (4 h cap) and
        // replace-on-new-fire so the Dynamic Island stays readable.
        // The activity controller no-ops on macOS — this whole branch
        // is iOS-only.
        await startOrUpdateLiveActivity(
            event: event,
            cameraID: cameraID,
            cameraName: cameraName,
            snapshotURL: attachment?.url
        )
        #endif
    }

    /// Persist the event to the App-Group container that widgets
    /// read from. Atomic, idempotent, and never throws into the
    /// caller — a failure here just means the widget will miss this
    /// fire (it'll catch up on the next one). AGENTS.md §16: no
    /// network, no Keychain, the container is device-local.
    private static func publishToWidgetContainer(
        event: BaichuanEvent,
        cameraID: UUID,
        cameraName: String,
        snapshotURL: URL?
    ) {
        let aiTags: [String]
        switch event.kind {
        case .ai(let tag): aiTags = [tag]
        case .motionStart, .motionStop: aiTags = ["motion"]
        case .other: aiTags = []
        }
        // Copy the snapshot into the App-Group `activity-assets/`
        // folder so the widget extension can read it without
        // re-downloading (it has no network entitlement).
        var assetRelativePath: String?
        if let snapshotURL,
           let jpegData = try? Data(contentsOf: snapshotURL),
           let assetURL = try? SharedContainer.writeActivityFrame(eventID: UUID(), jpegData: jpegData) {
            assetRelativePath = assetURL.lastPathComponent
        }
        let record = SharedContainer.RecentMotionEvent(
            id: UUID(),
            cameraID: cameraID,
            channel: Int(event.channelID),
            cameraName: cameraName,
            timestamp: Date(),
            aiTags: aiTags,
            triggerFrameRelativePath: assetRelativePath
        )
        try? SharedContainer.appendMotionEvent(record, cap: 50)

        // Bump lastMotionAt on the per-camera snapshot record so the
        // CameraSnapshotWidget's "fired Xm ago" subtitle is fresh.
        var snapshots = SharedContainer.readLatestSnapshots()
        if let index = snapshots.firstIndex(where: { $0.cameraID == cameraID && $0.channel == Int(event.channelID) }) {
            let prior = snapshots[index]
            snapshots[index] = SharedContainer.LatestSnapshot(
                cameraID: prior.cameraID,
                channel: prior.channel,
                cameraName: prior.cameraName,
                lastUpdated: prior.lastUpdated,
                imageRelativePath: prior.imageRelativePath,
                lastMotionAt: Date()
            )
            try? SharedContainer.writeLatestSnapshots(snapshots)
        }
        // Trigger widget reload so the new event appears within
        // seconds rather than at the next scheduled timeline tick.
        #if canImport(WidgetKit)
        Task { @MainActor in
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    #if os(iOS)
    private func startOrUpdateLiveActivity(
        event: BaichuanEvent,
        cameraID: UUID,
        cameraName: String,
        snapshotURL: URL?
    ) async {
        let aiTags: [String]
        switch event.kind {
        case .ai(let tag): aiTags = [tag]
        case .motionStart: aiTags = ["motion"]
        case .motionStop, .other: return
        }
        let jpegData = snapshotURL.flatMap { try? Data(contentsOf: $0) }
        // The controller lives in `AppiOS/Sources/LiveActivities/` —
        // not built by SPM. EventNotifier hands off via a small
        // protocol-typed bridge so AppShared doesn't import iOS-only
        // ActivityKit / MotionEventActivityController types.
        guard let bridge = Self.liveActivityBridge else { return }
        await bridge.start(
            cameraID: cameraID,
            channel: Int(event.channelID),
            cameraName: cameraName,
            aiTags: aiTags,
            triggerFrameJPEG: jpegData
        )
    }

    /// Set by the iOS app at launch (see `ReolensiOSApp.swift`'s
    /// init) to a real `MotionEventActivityController` adapter. Stays
    /// nil on macOS and in SPM unit tests — `startOrUpdateLiveActivity`
    /// is then a no-op.
    nonisolated(unsafe) public static var liveActivityBridge: (any MotionEventLiveActivityBridge)? = nil
    #endif

    /// Build the title/body for an event, plus a stable key for the
    /// throttle map. `nil`-keyed events return an empty triple so the
    /// macOS-only CloudKit relay hook. Publishes the record via the
    /// shared publisher. Errors are logged but never user-visible —
    /// relay is opportunistic; the local notification is the source
    /// of truth on this device.
    #if os(macOS)
    private func relayToCloudKit(event: BaichuanEvent, cameraID: UUID, snapshotFileURL: URL?) async {
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
            snapshotFileURL: snapshotFileURL
        )
        let publisher = CloudKitMotionEventPublisher()
        await publisher.publish(payload)
    }
    #endif

    /// Decision tree for a Baichuan event. Three outcomes:
    ///   - `.composed` — passed all `format`-level filters; this is
    ///     the title/body the user should see and the cache key for
    ///     the throttle.
    ///   - `.suppressedForLog` — the user has explicitly muted this
    ///     class of event (AI master off, per-tag off, or motion-only
    ///     off). The notification log records it so the user can see
    ///     "we got the event but you'd asked us to be quiet".
    ///   - `.ignored` — non-notifiable event kind (motion-stop, other)
    ///     that should never appear in the user log.
    enum FormatResult {
        case composed(title: String, body: String, throttleKey: String, tag: String?)
        case suppressedForLog(syntheticTitle: String, tag: String?, reason: NotificationRecord.DeliveryStatus)
        case ignored
    }

    func classify(event: BaichuanEvent, cameraName: String) -> FormatResult {
        switch event.kind {
        case .ai(let tag):
            let detection = DetectionType.fromReolinkString(tag)
            let label = detection?.label ?? tag.capitalized
            let synthetic = "\(label) detected"
            if !notifyAI {
                return .suppressedForLog(
                    syntheticTitle: synthetic,
                    tag: tag,
                    reason: .aiMutedGlobally
                )
            }
            // Per-tag filter (0.4.0). When the detection maps to a
            // known DetectionType, honor the user's per-tag toggle.
            // Unknown tags fall through with the master `notifyAI`
            // gate above so the firmware can roll out new categories
            // without us silently dropping them.
            if let detection, notifyPerTag[detection] == false {
                return .suppressedForLog(
                    syntheticTitle: synthetic,
                    tag: tag,
                    reason: .tagMuted
                )
            }
            return .composed(
                title: synthetic,
                body: cameraName,
                throttleKey: "\(event.channelID)-ai-\(tag)",
                tag: tag
            )
        case .motionStart:
            if !notifyMotion {
                return .suppressedForLog(
                    syntheticTitle: "Motion detected",
                    tag: nil,
                    reason: .motionMutedGlobally
                )
            }
            return .composed(
                title: "Motion detected",
                body: cameraName,
                throttleKey: "\(event.channelID)-motion",
                tag: nil
            )
        case .motionStop, .other:
            return .ignored
        }
    }

    /// Back-compat shim used by the existing `notify(...)` body until
    /// the call site is updated. Returns empty strings on every
    /// non-`.composed` result.
    func format(event: BaichuanEvent, cameraName: String) -> (title: String, body: String, throttleKey: String) {
        if case .composed(let title, let body, let key, _) = classify(event: event, cameraName: cameraName) {
            return (title, body, key)
        }
        return ("", "", "")
    }

    private func consumeLocalNotificationCooldown(for key: String) -> Bool {
        if let last = lastNotifiedAt[key],
           Date().timeIntervalSince(last) < Self.cooldown {
            return false
        }
        lastNotifiedAt[key] = Date()
        return true
    }

    private func consumeRelayCooldown(for key: String) -> Bool {
        if let last = lastRelayedAt[key],
           Date().timeIntervalSince(last) < Self.cooldown {
            return false
        }
        lastRelayedAt[key] = Date()
        return true
    }

    /// Write a dropped-event record into the notification log. Called
    /// from every early-return path in `notify(...)` so the user can
    /// see motion events that fired on a camera but were silenced by
    /// a setting they may have forgotten about. The synthesized title
    /// matches what the notification would have read if delivered, so
    /// the log entry is recognizable.
    func logDroppedEvent(
        event: BaichuanEvent,
        cameraID: UUID,
        cameraName: String,
        title: String,
        tag: String?,
        reason: NotificationRecord.DeliveryStatus
    ) async {
        let record = NotificationRecord(
            timestamp: Date(),
            source: .local,
            cameraID: cameraID,
            channel: Int(event.channelID),
            cameraName: cameraName,
            detectionTag: tag,
            title: title,
            body: cameraName,
            thumbnailRelativePath: nil,
            deliveryStatus: reason
        )
        await NotificationHistory.shared.record(record)
    }

    /// Download the snapshot JPEG to a temp file and wrap it in a
    /// `UNNotificationAttachment`. AppKit auto-moves the file into its
    /// own storage on `add(request:)`, so we don't need to keep the temp
    /// path around afterward.
    private func downloadSnapshotAttachment(from url: URL) async -> UNNotificationAttachment? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
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

        // 0.5.0 Theme A5 — digest notification tap routes to the
        // digest detail sheet. Recognized by category identifier so
        // the digest path doesn't share the cameraID/channel
        // contract of the alarm notifications.
        if response.notification.request.content.categoryIdentifier == DigestScheduler.notificationCategory {
            let dayEpoch = userInfo[DigestScheduler.userInfoDigestDayKey] as? TimeInterval
            let day = dayEpoch.map { Date(timeIntervalSince1970: $0) } ?? Date()
            AppIntentFocus.request(.digest(day: day))
            // Also re-build the digest in case the user tapped the
            // scheduled placeholder before the app had a chance to
            // run the pipeline (cold-launch tap).
            Task {
                await DigestScheduler.shared.runDigest(now: day)
            }
            return
        }

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

        // 0.6.0 — record the tap in the notification history so the
        // log can show which notifications the user actually engaged
        // with. The notification's request.identifier was set to the
        // `NotificationRecord.id.uuidString` in `EventNotifier.notify()`
        // and `AppDelegate.postLocalNotification(for:)`, so this is the
        // stable handle.
        if let recordID = UUID(uuidString: response.notification.request.identifier) {
            Task { await NotificationHistory.shared.markTapped(id: recordID) }
        }

        // The running app's foreground/launch task drains the pointer
        // and routes. We also kick a Darwin notification post here to
        // help wake the app if it was suspended — but the standard
        // delegate flow already foregrounds for `didReceive`, so this
        // is belt-and-suspenders.
    }
}

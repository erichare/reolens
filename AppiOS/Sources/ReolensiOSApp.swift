import SwiftUI
import UIKit
import CloudKit
import UserNotifications
import AppShared
import ReolinkAPI
import os

@main
struct ReolensiOSApp: App {
    /// `UIApplicationDelegateAdaptor` so we can install the
    /// `NotificationTapDelegate` during `didFinishLaunchingWithOptions`.
    /// That timing is essential for cold-launch notification taps —
    /// installing in scene `.task` is too late, because iOS attempts
    /// to dispatch the tap response before the scene has even
    /// mounted.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared camera model. Lives for the lifetime of the app and is
    /// injected into every view via `.environment(_:)`. The store wakes
    /// up the iCloud Drive sync helper in its initializer, so cameras
    /// added on the Mac (or any other signed-in device) appear here
    /// without any explicit pull on launch.
    @State private var store = CameraStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    // Drain any pending intent the user fired before
                    // the app was running (Shortcuts/Siri or a
                    // notification tap on a cold launch — both write
                    // to the same UserDefaults pointer via
                    // `AppIntentFocus.request`; `CameraStore` consumes
                    // it here). The delegate itself is already
                    // installed by AppDelegate.
                    store.applyPendingIntentFocus()

                    // Auto-request notification permission on first
                    // launch — matches the macOS app's behavior. Until
                    // 0.4.0, iOS users had to dig into Settings → "Request
                    // permission" before any motion notification could
                    // fire, so for the vast majority of users the rich
                    // alarm notifications listed in the README simply
                    // never appeared. `EventNotifier.notify` is gated by
                    // `permissionStatus == .authorized`, which can only
                    // reach `.authorized` after a prompt the user
                    // accepts. The status check makes this idempotent —
                    // subsequent launches no-op because the OS records
                    // the user's decision permanently.
                    await EventNotifier.shared.refreshPermissionStatus()
                    if EventNotifier.shared.permissionStatus == .notDetermined {
                        await EventNotifier.shared.requestPermission()
                    }

                    // CloudKit motion-event subscription (0.4.1).
                    // Installs idempotently on every launch — CloudKit
                    // no-ops on a re-register, so this is safe and
                    // survives schema drift. Background pushes wake
                    // the AppDelegate's didReceiveRemoteNotification
                    // handler; that handler does the local-notification
                    // fan-out. AGENTS.md §5 — runs inside the user's
                    // own iCloud account, no Reolens server.
                    if MotionEventRelaySettings.subscriberEnabled {
                        await CloudKitMotionEventSubscriber().installSubscriptionIfNeeded()
                        await MainActor.run {
                            UIApplication.shared.registerForRemoteNotifications()
                        }
                    }
                }
                .onContinueUserActivity(CameraContinuity.cameraDetailActivityType) { activity in
                    if CameraContinuity.handle(activity: activity) {
                        store.applyPendingIntentFocus()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.applyPendingIntentFocus()
                    }
                }
                // Drain when a focus request is written AFTER the
                // scene's launch `.task` ran — typically the
                // cold-launch-via-notification-tap path, where
                // `NotificationTapDelegate.didReceive` fires after
                // `application(_:didFinishLaunchingWithOptions:)` and
                // the scene is already `.active`, so the scenePhase
                // observer doesn't catch the transition.
                .onReceive(NotificationCenter.default.publisher(for: AppIntentFocus.didUpdate)) { _ in
                    store.applyPendingIntentFocus()
                }
                // TLS pinning mismatches surface as a global sheet so
                // they can't be missed in any specific tab. AGENTS.md
                // §3 — TLS changes need explicit user re-consent.
                .sheet(item: Binding(
                    get: { store.pendingTrustChange },
                    set: { store.pendingTrustChange = $0 }
                )) { request in
                    TrustChangedSheet(request: request)
                        .environment(store)
                }
                // Same Keychain-write-failure alert as macOS — turns
                // silent password-save failures into observable ones.
                .alert(
                    "Couldn't save password",
                    isPresented: Binding(
                        get: { store.passwordSaveError != nil },
                        set: { isShown in if !isShown { store.passwordSaveError = nil } }
                    ),
                    presenting: store.passwordSaveError
                ) { _ in
                    Button("OK", role: .cancel) {
                        store.passwordSaveError = nil
                    }
                } message: { err in
                    Text(err.message)
                }
        }
    }
}

/// `UIApplicationDelegate` that installs the notification-tap delegate
/// early in the launch sequence. SwiftUI scenes mount AFTER
/// `didFinishLaunchingWithOptions` returns, so installing in
/// `.task` could miss a cold-launch tap — the response may be
/// dispatched before the scene appears. Doing it here guarantees the
/// delegate is in place no matter how the app comes up.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "MotionRelay")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationTapDelegate.install()
        return true
    }

    // MARK: - CloudKit motion-event push handling (0.4.1)

    /// Apple Push registration outcome. Required for CloudKit silent
    /// pushes to be delivered — without `registerForRemoteNotifications`
    /// returning successfully, CloudKit subscriptions never fire on
    /// device. APNS token itself isn't used by Reolens (we don't have
    /// our own push server); we just need the registration handshake.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Token is opaque to us — CloudKit handles its own routing.
        // Don't log token bytes (privacy).
        log.info("APNS registered (\(deviceToken.count) byte token)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        log.warning("APNS registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// CloudKit silent-push entry point. iOS wakes the app briefly
    /// (≤30 s) and hands us the CloudKit notification metadata. We
    /// fetch the new MotionEvent record, post a local notification
    /// with the snapshot attachment, and call back with the
    /// background-fetch result.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            completionHandler(.noData)
            return
        }
        // We only care about query subscriptions on the MotionEvent
        // record type. Other CKNotification kinds (database changes
        // unrelated to our subscription) get noData.
        guard let queryNotification = notification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            completionHandler(.noData)
            return
        }
        Task {
            let subscriber = CloudKitMotionEventSubscriber()
            if let motionEvent = await subscriber.fetch(recordID: recordID) {
                await postLocalNotification(for: motionEvent)
                completionHandler(.newData)
            } else {
                completionHandler(.failed)
            }
        }
    }

    /// Compose + post a local notification from a fetched motion
    /// event. Runs the same `EventNotifier`-style format / throttle /
    /// permission gates so the user's notification preferences (per-
    /// tag mutes, motion-only off, master enable) apply uniformly
    /// to local AND relayed events.
    private func postLocalNotification(for event: MotionEvent) async {
        // Honor master + per-tag user preferences before posting.
        let notifier = EventNotifier.shared
        guard await MainActor.run(body: { notifier.enabled }) else { return }
        let detection = ReolinkAPI.DetectionType.fromReolinkString(event.detection)
        let title: String
        if let detection {
            // Per-tag user gate, mirroring local-notification path.
            let perTagOn = await MainActor.run { notifier.notifyPerTag[detection] ?? true }
            let aiOn = await MainActor.run { notifier.notifyAI }
            guard aiOn, perTagOn else { return }
            title = "\(detection.label) detected"
        } else if event.detection == "motion" {
            let motionOn = await MainActor.run { notifier.notifyMotion }
            guard motionOn else { return }
            title = "Motion detected"
        } else {
            return
        }
        let cameraName = await MainActor.run {
            // Without the camera list at hand here, fall back to a
            // generic body — the CameraStore is owned by the SwiftUI
            // scene, not this AppDelegate. The notification tap
            // routing still uses the camera UUID to navigate.
            "Camera \(event.channel + 1)"
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = cameraName
        content.sound = .default
        content.threadIdentifier = "ch-\(event.channel)"
        content.categoryIdentifier = "reolens.alarm"
        content.userInfo = [
            EventNotifier.userInfoCameraIDKey: event.cameraID.uuidString,
            EventNotifier.userInfoChannelKey: event.channel,
            EventNotifier.userInfoEventTimeKey: event.timestamp.timeIntervalSince1970,
        ]
        if let snapshotURL = event.snapshotFileURL {
            // CloudKit-staged snapshots arrive as local file URLs;
            // copy into our temp dir with a recognized extension so
            // UNNotificationAttachment accepts them.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("reolens-relay-\(UUID().uuidString).jpg")
            if (try? FileManager.default.copyItem(at: snapshotURL, to: dest)) != nil,
               let attachment = try? UNNotificationAttachment(
                identifier: dest.lastPathComponent,
                url: dest,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
               ) {
                content.attachments = [attachment]
            }
        }
        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil
        )
        _ = try? await UNUserNotificationCenter.current().add(request)
        log.info("Posted relayed motion notification (channel \(event.channel), detection \(event.detection, privacy: .public))")
    }
}


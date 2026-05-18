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

                    // 0.5.0 Theme A5 — reconcile the daily overnight
                    // digest with the user's current settings. The
                    // scheduled local notification fires at the
                    // configured hour without any background mode;
                    // `UNCalendarNotificationTrigger(repeats: true)`
                    // handles the daily fire.
                    await DigestScheduler.shared.reconcileSchedule()

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
                    switch phase {
                    case .active:
                        store.applyPendingIntentFocus()
                        // 0.5.1 — start (or resume) the background
                        // snapshot prefetcher. Idempotent. Battery
                        // cameras are skipped inside the prefetcher
                        // — see CameraPreviewPrefetcher header.
                        CameraPreviewPrefetcher.shared.start(store: store)
                        Task { await CameraPreviewPrefetcher.shared.sweepNow() }
                        // 0.6.0 — reconcile bookmark downloads. Picks
                        // up any bookmark whose background download
                        // failed / was killed and re-enqueues it now
                        // that we have working sessions. The
                        // reconciler waits for each session to reach
                        // `.connected` before reading its token, so
                        // calling it on every `.active` is safe.
                        Task {
                            let sessions = await MainActor.run {
                                store.cameras.compactMap { store.session(for: $0.id) }
                            }
                            await BookmarkAutoDownloader.shared.reconcile(across: sessions)
                        }
                        // 0.6.0 — bump every CameraSession's poll
                        // cadence back to foreground (10 s). The next
                        // poll iteration picks up the shorter interval.
                        AdaptivePollSchedule.shared.enteredForeground()
                    case .background:
                        // Cancel the periodic loop while backgrounded
                        // so we don't fire snapshot HTTP calls iOS
                        // would interrupt anyway. The next .active
                        // transition kicks an immediate sweep.
                        CameraPreviewPrefetcher.shared.stop()
                        // 0.6.0 — relax motion polling to 60 s while
                        // suspended (or 120 s under Low Power Mode).
                        AdaptivePollSchedule.shared.enteredBackground()
                    default:
                        break
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
                // 0.5.0 Theme A5 — digest sheet, presented when a
                // digest notification tap routes through
                // `applyPendingIntentFocus()`.
                .sheet(item: Binding<DigestDaySheet?>(
                    get: { store.pendingDigestDay.map { DigestDaySheet(day: $0) } },
                    set: { _ in store.pendingDigestDay = nil }
                )) { sheet in
                    DigestDetailView(requestedDay: sheet.day)
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

        // 0.5.0 Theme A4 — secondary scene for iPadOS "Open in New
        // Window". The iPadOS sidebar's per-camera context menu uses
        // `openWindow(value: ReolensScene.camera(...))` which matches
        // here. SwiftUI handles multi-scene state on iPadOS Stage
        // Manager automatically; on iPhone (no multi-window), this
        // scene declaration is harmless.
        WindowGroup(for: ReolensScene.self) { $scene in
            CameraSceneHostiOS(scene: scene ?? .main)
                .environment(store)
        }
    }
}

/// 0.5.0 Theme A4 — iOS twin of `App/Views/CameraSceneHost.swift`.
/// Resolves a `ReolensScene` value into the matching view; the
/// camera case dives straight into the channel's live view.
private struct CameraSceneHostiOS: View {
    let scene: ReolensScene
    @Environment(CameraStore.self) private var store

    var body: some View {
        switch scene {
        case .main:
            RootView()
        case .camera(let id, let channel):
            if let session = store.sessions[id],
               let ch = session.liveChannels.first(where: { $0.channel == channel })
                ?? session.channels.first(where: { $0.channel == channel }) {
                SingleChannelView(session: session, channel: ch)
            } else {
                ContentUnavailableView(
                    "Camera not available",
                    systemImage: "video.slash",
                    description: Text("Reolens lost the session for this camera. Reopen it from the main window.")
                )
            }
        case .digest:
            RootView()
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
        let tokenLength = deviceToken.count
        Task { await RelayDiagnostics.shared.recordAPNSRegistered(tokenByteCount: tokenLength) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        log.warning("APNS registration failed: \(error.localizedDescription, privacy: .public)")
        let message = error.localizedDescription
        Task { await RelayDiagnostics.shared.recordAPNSFailed(message: message) }
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
            // Record arrival before fetch — the silent push got through
            // APNS + CloudKit even if the record fetch later fails. This
            // is the signal the diagnostic screen needs to confirm the
            // push pipeline is alive.
            await RelayDiagnostics.shared.recordSilentPushReceived()
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
        // Prefer the publisher-supplied name embedded in the CKRecord.
        // Falls back to "Camera <n+1>" only for legacy records written
        // before the `cameraName` field was deployed to Production.
        let cameraNameFallback = event.cameraName ?? "Camera \(event.channel + 1)"
        let detection = ReolinkAPI.DetectionType.fromReolinkString(event.detection)
        let syntheticTitle: String
        if let detection {
            syntheticTitle = "\(detection.label) detected"
        } else if event.detection == "motion" {
            syntheticTitle = "Motion detected"
        } else if event.detection == "test" {
            syntheticTitle = "Reolens test event received"
        } else {
            return
        }

        // 0.6.0 — log silent drops to the notification history so users
        // can see relayed events that didn't surface as a banner.
        func logDrop(_ status: NotificationRecord.DeliveryStatus) async {
            let record = NotificationRecord(
                id: event.id,
                timestamp: event.timestamp,
                source: .cloudKitSilentPush,
                cameraID: event.cameraID,
                channel: event.channel,
                cameraName: cameraNameFallback,
                detectionTag: detection?.rawValue ?? event.detection,
                title: syntheticTitle,
                body: cameraNameFallback,
                thumbnailRelativePath: nil,
                deliveryStatus: status
            )
            await NotificationHistory.shared.record(record)
        }

        guard await MainActor.run(body: { notifier.enabled }) else {
            await logDrop(.globallyDisabled)
            return
        }
        if let detection {
            // Per-tag user gate, mirroring local-notification path.
            let perTagOn = await MainActor.run { notifier.notifyPerTag[detection] ?? true }
            let aiOn = await MainActor.run { notifier.notifyAI }
            if !aiOn { await logDrop(.aiMutedGlobally); return }
            if !perTagOn { await logDrop(.tagMuted); return }
        } else if event.detection == "motion" {
            let motionOn = await MainActor.run { notifier.notifyMotion }
            if !motionOn { await logDrop(.motionMutedGlobally); return }
        }
        let title = syntheticTitle
        let cameraName = cameraNameFallback
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
        // 0.6.7 — `content` is built for parity with the in-app
        // notification log (and a future Notification Service
        // Extension that will use it to enrich the system-delivered
        // alert push). We DO NOT add it as a UNNotificationRequest:
        // the v2 CKQuerySubscription now delivers the push as a
        // user-visible alert via APNs (see
        // CloudKitMotionEventSubscriber.installSubscriptionIfNeeded),
        // and posting a second local notification here would surface
        // two banners for the same event. We still feed the
        // notification log, widget container, and per-camera health
        // badge below so those features keep working for relayed
        // events. `content` is intentionally unused at runtime today
        // — keeping the construction in place so the NSE follow-up
        // can adopt it without re-deriving the same fields.
        _ = content
        log.info("Relayed motion received (channel \(event.channel), detection \(event.detection, privacy: .public)) — alert push handled by APNs")

        // 0.6.0 — record the relayed event into the user-facing
        // notification log so iPhone/iPad users see CloudKit-delivered
        // events alongside local ones, with the right source tag.
        let postedRecord = NotificationRecord(
            id: event.id,
            timestamp: event.timestamp,
            source: .cloudKitSilentPush,
            cameraID: event.cameraID,
            channel: event.channel,
            cameraName: cameraName,
            detectionTag: detection?.rawValue ?? event.detection,
            title: title,
            body: cameraName,
            thumbnailRelativePath: nil,
            deliveryStatus: .posted
        )
        await NotificationHistory.shared.record(postedRecord)

        // 0.6.0 — feed the per-camera health badge + widgets on iOS too.
        // Until now only the macOS publisher path wrote to the shared
        // widget log via `EventNotifier`; CloudKit-relayed events arriving
        // on iOS skipped this entirely, leaving widgets and badges stale.
        let widgetEvent = SharedContainer.RecentMotionEvent(
            id: event.id,
            cameraID: event.cameraID,
            channel: event.channel,
            cameraName: cameraName,
            timestamp: event.timestamp,
            aiTags: detection.map { [$0.label] } ?? [],
            triggerFrameRelativePath: nil
        )
        try? SharedContainer.appendMotionEvent(widgetEvent)
        await MainActor.run {
            CameraNotificationHealth.shared.refresh()
        }
    }
}

/// 0.5.0 Theme A5 — `Identifiable` wrapper for `Date` so the digest
/// sheet's `.sheet(item:)` binding has a stable identity that matches
/// the requested-day epoch. Mirrors `App/ReolensApp.swift`.
private struct DigestDaySheet: Identifiable {
    let day: Date
    var id: TimeInterval { day.timeIntervalSince1970 }
}


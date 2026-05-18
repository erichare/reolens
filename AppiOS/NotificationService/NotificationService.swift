//
//  NotificationService.swift
//
//  Notification Service Extension (0.6.7). Enriches CloudKit motion-
//  event alert pushes with a detection-specific title and a snapshot
//  attachment before iOS shows the banner.
//
//  Flow:
//    1. APNs delivers the alert push from the CKQuerySubscription
//       installed by `CloudKitMotionEventSubscriber`. The
//       subscription's NotificationInfo sets
//       `shouldSendMutableContent = true`, which causes iOS to
//       launch this extension before displaying the notification.
//    2. We parse the CKQueryNotification payload, read inline record
//       fields (detection, channel) populated by `desiredKeys`, and
//       rewrite the subscription's literal "Motion detected" body
//       with a specific title like "Person detected".
//    3. We fetch the full record from the user's private CloudKit
//       database to pull the snapshot CKAsset and attach it.
//    4. `contentHandler` is invoked with the enriched content. If we
//       run out of time, `serviceExtensionTimeWillExpire` flushes
//       whatever has been built so far — the user still sees a
//       richer banner than the subscription default.
//
//  Memory + time budget: ~24 MB / 30 s. Kept dependency-light — no
//  AppShared import — so the binary stays small. The container ID
//  and CKRecord field-name literals are mirrors of constants in
//  `AppShared/MotionEventRelay.swift`; keep them in sync.
//
//  Concurrency: we deliberately use the callback-style CloudKit API
//  rather than the async/await overloads. The NSE class subclasses
//  the non-Sendable `UNNotificationServiceExtension` and mutates a
//  non-Sendable `UNMutableNotificationContent`. Under Swift 6
//  strict-concurrency, hopping these across a `Task { … }` boundary
//  requires either marking everything `@unchecked Sendable` or
//  threading `nonisolated(unsafe)` through every captured reference.
//  CloudKit's completion-handler API stays on a single queue, sidestepping
//  the boundary crossing entirely.
//

// `@preconcurrency` because `UNMutableNotificationContent` is not
// declared Sendable in the public framework headers, but we
// confine the instance to a single CloudKit completion queue —
// see the long Concurrency note in the file header.
@preconcurrency import UserNotifications
import CloudKit
import os

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {

    /// Source of truth: `CloudKitMotionEventPublisher.containerID`.
    /// Hardcoded here to avoid an AppShared import in the NSE binary.
    private static let containerID = "iCloud.com.reolens.Reolens"

    /// Mirrors of `MotionEvent.RecordKey.*` in AppShared. Pinned to
    /// strings so the NSE doesn't pull the AppShared module just for
    /// four constants.
    private static let recordKeyDetection = "detection"
    private static let recordKeyChannel = "channel"
    private static let recordKeyCameraID = "cameraID"
    private static let recordKeySnapshot = "snapshot"

    private let log = Logger(
        subsystem: "com.reolens.Reolens",
        category: "NotificationService"
    )

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttempt = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // CloudKit subscription pushes arrive as plist-encoded
        // dictionaries in `UNNotificationContent.userInfo`. Anything
        // that doesn't decode as a CKQueryNotification we pass
        // through unchanged — e.g. a future non-CK alert path or a
        // malformed payload.
        let userInfo = request.content.userInfo
        guard
            let raw = userInfo as? [String: Any],
            let notification = CKNotification(fromRemoteNotificationDictionary: raw) as? CKQueryNotification
        else {
            log.info("Not a CKQueryNotification; delivering unchanged")
            contentHandler(bestAttempt)
            return
        }

        // Step 1 — synchronously enrich title/body from inline record
        // fields. These are populated by `desiredKeys` on the
        // subscription, so they cost no network round trip.
        applyInlineFieldEnrichment(notification: notification, content: bestAttempt)

        // Step 2 — asynchronously fetch the full record to download
        // the snapshot CKAsset. CKAssets aren't embedded in the
        // desired-keys push payload; they require a record fetch.
        // The NSE has a ~30 s budget; if the fetch overruns,
        // `serviceExtensionTimeWillExpire` delivers whatever has been
        // built so far. We use the completion-handler API so the
        // entire flow stays on a single CloudKit queue — no Task /
        // actor hop needed for the non-Sendable mutable content.
        guard let recordID = notification.recordID else {
            log.info("No recordID on CKQueryNotification; delivering inline-only")
            deliver(bestAttempt)
            return
        }

        let container = CKContainer(identifier: Self.containerID)
        let db = container.privateCloudDatabase
        let recordKeySnapshot = Self.recordKeySnapshot
        db.fetch(withRecordID: recordID) { [weak self] record, error in
            guard let self else { return }
            if let error {
                self.log.warning("NSE snapshot fetch failed: \(error.localizedDescription, privacy: .public)")
            } else if let record, let asset = record[recordKeySnapshot] as? CKAsset, let assetURL = asset.fileURL {
                Self.attach(snapshotURL: assetURL, to: bestAttempt, log: self.log)
            }
            self.deliver(bestAttempt)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // The system is about to terminate the extension. Deliver
        // whatever we've enriched so far — worst case, the user sees
        // the subscription's default "Motion detected" banner.
        log.info("NSE time will expire; flushing best-effort content")
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
            contentHandler = nil
        }
    }

    // MARK: - Helpers

    private func deliver(_ content: UNNotificationContent) {
        // Guarded to handle the rare race where
        // `serviceExtensionTimeWillExpire` fired first and already
        // delivered. Both paths null the handler so only one ever
        // wins.
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }

    private func applyInlineFieldEnrichment(
        notification: CKQueryNotification,
        content: UNMutableNotificationContent
    ) {
        let fields = notification.recordFields ?? [:]
        let detection = fields[Self.recordKeyDetection] as? String
        let channel = fields[Self.recordKeyChannel] as? Int

        if let detection {
            content.title = title(forDetection: detection)
        }
        if let channel {
            content.body = "Channel \(channel + 1)"
            content.threadIdentifier = "ch-\(channel)"
        }
        // Carry the camera UUID + channel + event time forward in
        // userInfo so a tap can route into the right camera. The
        // tap delegate in AppShared reads `cameraID` / `channelID` /
        // `eventTime` keys (see EventNotifier.userInfoCameraIDKey).
        var enrichedUserInfo = content.userInfo
        if let cameraIDString = fields[Self.recordKeyCameraID] as? String {
            enrichedUserInfo["cameraID"] = cameraIDString
        }
        if let channel {
            enrichedUserInfo["channelID"] = channel
        }
        enrichedUserInfo["eventTime"] = Date().timeIntervalSince1970
        content.userInfo = enrichedUserInfo
        // Group with locally-posted alarm notifications so the
        // category identifier matches and any future custom actions
        // (e.g. "View live" / "Snooze") apply to relayed events too.
        content.categoryIdentifier = "reolens.alarm"
    }

    private static func attach(
        snapshotURL: URL,
        to content: UNMutableNotificationContent,
        log: Logger
    ) {
        // UNNotificationAttachment requires the file to exist at its
        // referenced URL until the system reads it after
        // contentHandler returns. Copying into our own temp file
        // with a recognized extension also lets the OS detect the
        // type without relying on the CKAsset's opaque temp path.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-nse-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: snapshotURL, to: dest)
            let attachment = try UNNotificationAttachment(
                identifier: dest.lastPathComponent,
                url: dest,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
            )
            content.attachments = [attachment]
        } catch {
            log.warning("NSE attachment build failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Title strings parallel `AppDelegate.postLocalNotification(for:)`
    /// in `AppiOS/Sources/ReolensiOSApp.swift` so locally-posted and
    /// relay-enriched banners read the same. Burst summaries collapse
    /// to a generic "Activity burst detected" so a sustained scene
    /// (rain, foot traffic) is recognizable in Notification Center.
    private func title(forDetection detection: String) -> String {
        if detection.hasSuffix(".burst") {
            return "Activity burst detected"
        }
        switch detection {
        case "test":
            return "Reolens test event received"
        case "motion":
            return "Motion detected"
        case "people", "person":
            return "Person detected"
        case "vehicle":
            return "Vehicle detected"
        case "dog_cat", "pet":
            return "Pet detected"
        case "face":
            return "Face detected"
        case "package":
            return "Package detected"
        default:
            return "Motion detected"
        }
    }
}

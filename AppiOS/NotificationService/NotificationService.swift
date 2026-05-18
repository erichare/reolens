//
//  NotificationService.swift
//
//  Notification Service Extension. Enriches CloudKit motion-event
//  alert pushes with a detection-specific title and a snapshot
//  attachment before iOS shows the banner.
//
//  Flow:
//    1. APNs delivers the alert push from the CKQuerySubscription
//       installed by `CloudKitMotionEventSubscriber`. The
//       subscription's NotificationInfo sets
//       `shouldSendMutableContent = true`, which causes iOS to
//       launch this extension before displaying the notification.
//    2. We parse the CKQueryNotification payload to recover the
//       triggering record's ID.
//    3. We fetch the full record from the user's private CloudKit
//       database, then rewrite the subscription's literal "Motion
//       detected" body with a specific title like "Person detected"
//       (from `detection`) and attach the snapshot CKAsset.
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
    /// five constants.
    private static let recordKeyDetection = "detection"
    private static let recordKeyChannel = "channel"
    private static let recordKeyCameraID = "cameraID"
    private static let recordKeySnapshot = "snapshot"
    private static let recordKeyCameraName = "cameraName"

    /// App Group used for cross-process telemetry. Must match the
    /// `application-groups` entitlement on both the host iOS app and
    /// the NSE bundle. Mirror of `SharedContainer.appGroupID`.
    private static let appGroupID = "group.com.reolens.Reolens"

    /// UserDefaults keys for NSE telemetry. Read by `RelayDiagnostics`
    /// in the host app so the user can see whether the extension is
    /// being invoked and how its CloudKit fetch is faring without
    /// crawling unified logs.
    private static let telemetryKeyCount = "nse.invocationCount"
    private static let telemetryKeyLastOutcome = "nse.lastOutcome"
    private static let telemetryKeyLastDate = "nse.lastInvocationDate"

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
        Self.bumpInvocationCount()
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttempt = bestAttemptContent else {
            Self.recordOutcome("noMutableCopy")
            contentHandler(request.content)
            return
        }

        // Sentinel: even if the CloudKit fetch below fails or times
        // out, "Reolens" as the title proves the NSE ran. If the user
        // ever sees a "Motion detected" banner with no Reolens title,
        // the NSE itself isn't being invoked (extension wiring problem,
        // not a fetch problem).
        bestAttempt.title = "Reolens"

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
            Self.recordOutcome("notCKNotification")
            contentHandler(bestAttempt)
            return
        }

        // Fetch the full record. The subscription no longer sets
        // `desiredKeys` (see v4 note in MotionEventRelay.swift), so
        // every enrichment field — title, body, and snapshot asset —
        // comes from this fetch. CKAssets always require a fetch
        // anyway; folding the other fields in costs nothing extra.
        // The NSE has a ~30 s budget; if the fetch overruns,
        // `serviceExtensionTimeWillExpire` delivers whatever has been
        // built so far. We use the completion-handler API so the
        // entire flow stays on a single CloudKit queue — no Task /
        // actor hop needed for the non-Sendable mutable content.
        guard let recordID = notification.recordID else {
            log.info("No recordID on CKQueryNotification; delivering unenriched")
            Self.recordOutcome("noRecordID")
            deliver(bestAttempt)
            return
        }

        let container = CKContainer(identifier: Self.containerID)
        let db = container.privateCloudDatabase
        fetchWithRetry(db: db, recordID: recordID, attempt: 1, bestAttempt: bestAttempt)
    }

    /// Delay schedule for retries on `.unknownItem`. The total elapsed
    /// time before giving up is the sum of these (~8.5 s) plus the
    /// roughly-1 s per attempt RTT, comfortably under the NSE's 30 s
    /// budget and still leaving room to download the snapshot asset
    /// after the record is found.
    ///
    /// Why so generous: in the field on production TestFlight + DMG
    /// builds we observed the host app's `didReceiveRemoteNotification`
    /// fetch succeed while the NSE's parallel fetch returned
    /// `.unknownItem`. Same record, same recordID, same iCloud account
    /// — the NSE just races CloudKit's internal replication. The host
    /// app wins because its fetch happens a couple of seconds later
    /// after the iOS push-delivery wake path lands. The NSE has to
    /// wait it out.
    private static let unknownItemRetryDelays: [TimeInterval] = [1.0, 2.5, 5.0]

    /// CloudKit fetch with retry on `.unknownItem`.
    ///
    /// 0.6.11 — observed in the field: the subscription push arrives
    /// before the new record has propagated through CloudKit's
    /// internal replication, so an immediate fetch returns CKError 11
    /// (`.unknownItem`). We retry with exponential backoff
    /// (`unknownItemRetryDelays`) before giving up. After the last
    /// attempt fails we fall through to the "Reolens" sentinel title
    /// + a generic "Camera event" body so the user still gets a
    /// banner that signals the relay is alive.
    private func fetchWithRetry(
        db: CKDatabase,
        recordID: CKRecord.ID,
        attempt: Int,
        bestAttempt: UNMutableNotificationContent
    ) {
        db.fetch(withRecordID: recordID) { [weak self] record, error in
            guard let self else { return }
            if let error {
                let isUnknownItem = (error as? CKError)?.code == .unknownItem
                if isUnknownItem, attempt < Self.unknownItemRetryDelays.count + 1 {
                    let delay = Self.unknownItemRetryDelays[attempt - 1]
                    self.log.info("NSE fetch returned unknownItem (attempt \(attempt)); retrying in \(delay)s")
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.fetchWithRetry(db: db, recordID: recordID, attempt: attempt + 1, bestAttempt: bestAttempt)
                    }
                    return
                }
                self.log.warning("NSE record fetch failed: \(error.localizedDescription, privacy: .public)")
                Self.recordOutcome("fetchError:\(Self.shortDescription(of: error))")
                // Give the user a banner that signals "we know an
                // event fired but couldn't enrich it" rather than the
                // bare subscription default — easier to diagnose,
                // less alarming than a silent "Motion detected".
                self.applyFallbackBody(to: bestAttempt, reason: error)
            } else if let record {
                self.enrich(from: record, content: bestAttempt)
                if let asset = record[Self.recordKeySnapshot] as? CKAsset,
                   let assetURL = asset.fileURL {
                    Self.attach(snapshotURL: assetURL, to: bestAttempt, log: self.log)
                }
                Self.recordOutcome("success")
            } else {
                Self.recordOutcome("noRecord")
                self.applyFallbackBody(to: bestAttempt, reason: nil)
            }
            self.deliver(bestAttempt)
        }
    }

    /// Apply a friendly fallback body when CloudKit enrichment failed.
    /// "Camera event" beats the bare subscription default ("Motion
    /// detected") because it doesn't mislead the user into thinking
    /// the camera saw plain motion when in fact we couldn't tell.
    /// Title remains the "Reolens" sentinel set at the top of
    /// `didReceive(...)`.
    private func applyFallbackBody(
        to content: UNMutableNotificationContent,
        reason: (any Error)?
    ) {
        content.body = "Camera event — open Reolens for details"
    }

    override func serviceExtensionTimeWillExpire() {
        // The system is about to terminate the extension. Deliver
        // whatever we've enriched so far — worst case, the user sees
        // the subscription's default "Motion detected" banner.
        log.info("NSE time will expire; flushing best-effort content")
        Self.recordOutcome("timeExpired")
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
            contentHandler = nil
        }
    }

    // MARK: - Telemetry

    /// Increment the invocation counter in the App Group `UserDefaults`.
    /// Synchronous; runs on whatever queue iOS invoked the NSE on.
    /// Failures (e.g. App Group not provisioned) are intentionally
    /// silent — telemetry is best-effort.
    private static func bumpInvocationCount() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let current = defaults.integer(forKey: telemetryKeyCount)
        defaults.set(current + 1, forKey: telemetryKeyCount)
        defaults.set(Date().timeIntervalSince1970, forKey: telemetryKeyLastDate)
    }

    /// Record the final outcome string for the most recent NSE
    /// invocation. Read by `RelayDiagnostics` to surface in Settings.
    private static func recordOutcome(_ outcome: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(outcome, forKey: telemetryKeyLastOutcome)
        defaults.set(Date().timeIntervalSince1970, forKey: telemetryKeyLastDate)
    }

    /// Compact a CKError for inclusion in the outcome string. We avoid
    /// the full `localizedDescription` because it can be long and
    /// contains user-account-specific phrasing. Common codes are
    /// surfaced by symbolic name so the diagnostic row is meaningful
    /// at-a-glance ("unknownItem" beats "ckError(11)").
    private static func shortDescription(of error: any Error) -> String {
        if let ck = error as? CKError {
            return symbolicName(for: ck.code) ?? "ckError(\(ck.code.rawValue))"
        }
        return "\(type(of: error))"
    }

    private static func symbolicName(for code: CKError.Code) -> String? {
        switch code {
        case .unknownItem: return "unknownItem"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .notAuthenticated: return "notAuthenticated"
        case .quotaExceeded: return "quotaExceeded"
        case .permissionFailure: return "permissionFailure"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .zoneNotFound: return "zoneNotFound"
        case .badContainer: return "badContainer"
        case .missingEntitlement: return "missingEntitlement"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return nil
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

    private func enrich(
        from record: CKRecord,
        content: UNMutableNotificationContent
    ) {
        let detection = record[Self.recordKeyDetection] as? String
        let channel = record[Self.recordKeyChannel] as? Int
        let cameraName = (record[Self.recordKeyCameraName] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        if let detection {
            content.title = title(forDetection: detection)
        }
        // Prefer the publisher-supplied camera name when present.
        // Falls back to "Channel <n+1>" so legacy records written
        // before the `cameraName` field was promoted to Production
        // still produce a readable banner.
        if let cameraName {
            content.body = cameraName
        } else if let channel {
            content.body = "Channel \(channel + 1)"
        }
        if let channel {
            content.threadIdentifier = "ch-\(channel)"
        }
        // Carry the camera UUID + channel + event time forward in
        // userInfo so a tap can route into the right camera. The
        // tap delegate in AppShared reads `cameraID` / `channelID` /
        // `eventTime` keys (see EventNotifier.userInfoCameraIDKey).
        var enrichedUserInfo = content.userInfo
        if let cameraIDString = record[Self.recordKeyCameraID] as? String {
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

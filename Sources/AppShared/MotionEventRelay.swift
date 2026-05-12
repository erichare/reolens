import Foundation
import CloudKit
import ReolinkBaichuan
import ReolinkAPI
import os

/// Cross-device motion-event relay. Added in 0.4.1 as the
/// foundation of iOS background notifications without violating
/// AGENTS.md §5 ("no servers"). Mechanism:
///
///   1. A `MotionEventPublisher` (only the macOS app implements one
///      today, via `CloudKitMotionEventPublisher`) writes a
///      `MotionEvent` `CKRecord` to the user's own private CloudKit
///      database whenever a Baichuan motion / AI event fires.
///   2. A `MotionEventSubscriber` (the iOS app) installs a
///      `CKQuerySubscription` on the same record type. CloudKit
///      delivers a silent push to every device signed into the same
///      iCloud account; the subscriber fetches the new record on
///      wake and posts a local `UNUserNotificationCenter`
///      notification.
///
/// Privacy: lives entirely inside the user's iCloud account
/// (private DB, never shared). Reolens has no server in the loop —
/// CloudKit's "our server" is Apple, under the user's own iCloud
/// credentials. AGENTS.md §5 is satisfied. The data we write is the
/// minimum needed to compose a useful notification on the receiving
/// device: a camera UUID, a channel index, a detection-type string,
/// a timestamp, and an optional snapshot JPEG attachment.

/// The data we relay per event. Sized to fit inside CloudKit's
/// free-tier silent-push payload (≤ 4 KB metadata; the snapshot
/// goes as a CKAsset, fetched on demand).
public struct MotionEvent: Sendable, Equatable {
    public let id: UUID
    public let cameraID: UUID
    public let channel: Int
    /// Raw Reolink AI tag string ("people", "vehicle", "dog_cat", …)
    /// or "motion" for plain motion-start events. Receiving devices
    /// decode this to `DetectionType` for the notification body.
    public let detection: String
    public let timestamp: Date
    /// Optional file URL to a JPEG snapshot. Publisher uploads as
    /// `CKAsset`; receivers download lazily.
    public let snapshotFileURL: URL?

    public init(
        id: UUID = UUID(),
        cameraID: UUID,
        channel: Int,
        detection: String,
        timestamp: Date,
        snapshotFileURL: URL? = nil
    ) {
        self.id = id
        self.cameraID = cameraID
        self.channel = channel
        self.detection = detection
        self.timestamp = timestamp
        self.snapshotFileURL = snapshotFileURL
    }

    // MARK: CloudKit record bridge

    /// CKRecord type name. Pin once; never rename without a
    /// migration (CKQuerySubscriptions are tied to this name).
    public static let recordType = "MotionEvent"

    public enum RecordKey {
        public static let cameraID = "cameraID"
        public static let channel = "channel"
        public static let detection = "detection"
        public static let timestamp = "timestamp"
        public static let snapshot = "snapshot"
    }

    /// Build a `CKRecord` for publication. Record name is the
    /// event's UUID string so re-publication of the same event
    /// (rare but possible under retries) replaces rather than
    /// duplicates.
    public func toRecord(in zone: CKRecordZone.ID = .default) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[RecordKey.cameraID] = cameraID.uuidString as NSString
        record[RecordKey.channel] = channel as NSNumber
        record[RecordKey.detection] = detection as NSString
        record[RecordKey.timestamp] = timestamp as NSDate
        if let snapshotFileURL {
            record[RecordKey.snapshot] = CKAsset(fileURL: snapshotFileURL)
        }
        return record
    }

    /// Decode a `CKRecord` into a `MotionEvent`. Returns nil if any
    /// required field is missing — the receiver silently drops
    /// malformed records rather than crashing on a schema mismatch.
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let cameraIDString = record[RecordKey.cameraID] as? String,
              let cameraID = UUID(uuidString: cameraIDString),
              let channel = record[RecordKey.channel] as? Int,
              let detection = record[RecordKey.detection] as? String,
              let timestamp = record[RecordKey.timestamp] as? Date,
              let id = UUID(uuidString: record.recordID.recordName) else {
            return nil
        }
        let asset = record[RecordKey.snapshot] as? CKAsset
        self.id = id
        self.cameraID = cameraID
        self.channel = channel
        self.detection = detection
        self.timestamp = timestamp
        self.snapshotFileURL = asset?.fileURL
    }
}

/// Abstraction over the macOS-only publisher path so unit tests
/// (and a future fallback implementation, e.g. a webhook relay for
/// iOS-only households) can swap in without touching call sites.
public protocol MotionEventPublisher: Sendable {
    func publish(_ event: MotionEvent) async
}

/// Default no-op. Used on iOS (which is a subscriber, not a
/// publisher) and as a safe default when the user hasn't opted in.
public struct NoOpMotionEventPublisher: MotionEventPublisher {
    public init() {}
    public func publish(_ event: MotionEvent) async {}
}

/// Real CloudKit-backed publisher. Writes to the user's *private*
/// CloudKit database — never shared, never public. AGENTS.md §5.
public actor CloudKitMotionEventPublisher: MotionEventPublisher {
    private let containerID: String
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "MotionRelay")

    public init(containerID: String = "iCloud.com.reolens.Reolens") {
        self.containerID = containerID
    }

    public func publish(_ event: MotionEvent) async {
        // Hard-block when the running binary doesn't carry the
        // iCloud-container entitlement. `CKContainer(identifier:)`
        // calls `__cxa_throw_bad_array_new_length`-style EXC_BREAKPOINT
        // on entitlement-less binaries (observed on ad-hoc-signed
        // dev builds whose `Reolens.dev.entitlements` deliberately
        // drops the iCloud container to dodge AMFI launch failures).
        // The ubiquity-container probe is the cheapest reliable
        // proxy for "this binary has iCloud entitlements at all" —
        // returns nil with no side effects when the entitlement is
        // absent, doesn't trap.
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else {
            log.info("CloudKit unavailable on this binary (no iCloud entitlement); skipping relay")
            return
        }
        let container = CKContainer(identifier: containerID)
        let db = container.privateCloudDatabase
        let record = event.toRecord()
        do {
            _ = try await db.save(record)
            log.info("Relayed motion event for channel \(event.channel) (detection \(event.detection, privacy: .public))")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already published (e.g. retry after partial success).
            // Idempotent — CloudKit told us the record exists with a
            // matching recordName; nothing to do.
            log.debug("Motion event already in CloudKit (recordChanged)")
        } catch {
            log.warning("Motion event relay failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Cheap "do we have iCloud entitlements at all" probe. CloudKit's
/// `CKContainer.init` traps hard rather than returning an error when
/// the running binary lacks the iCloud-container entitlement (most
/// commonly: ad-hoc-signed dev builds whose entitlements file
/// drops the iCloud container to keep AMFI happy). The ubiquity
/// container API returns nil without side effects in the same case,
/// so it's a safe pre-flight check.
public enum CloudKitAvailability {
    /// Memoized so the file-system probe only runs once per process.
    /// Stored separately per container ID since the entitlement
    /// could grant some containers but not others.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    public static func canUseCloudKit(containerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[containerID] {
            return cached
        }
        // The ubiquity container API doesn't trap on entitlement-less
        // binaries — it just returns nil. CloudKit and the
        // iCloud-Drive container share the same `iCloud.<...>`
        // entitlement, so presence-of-ubiquity implies presence-of-
        // CloudKit on the same identifier.
        let url = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
        let available = url != nil
        cache[containerID] = available
        return available
    }
}

/// iOS subscriber wiring. Owns the `CKQuerySubscription` lifecycle
/// and the `CKDatabaseNotification` → local notification fan-out.
public actor CloudKitMotionEventSubscriber {
    private let containerID: String
    private let subscriptionID = "com.reolens.motionEvent.v1"
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "MotionRelay")

    public init(containerID: String = "iCloud.com.reolens.Reolens") {
        self.containerID = containerID
    }

    /// Idempotent. Installs (or refreshes) the subscription on first
    /// call. CloudKit silently no-ops a re-registration of an
    /// existing subscription ID, so calling on every app launch is
    /// safe and survives schema drift.
    public func installSubscriptionIfNeeded() async {
        // Same entitlement guard as the publisher — CKContainer.init
        // traps without iCloud entitlements. The check is a no-op on
        // properly-signed App Store / TestFlight / Developer-ID
        // builds.
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else {
            log.info("CloudKit unavailable; skipping subscription install")
            return
        }
        let container = CKContainer(identifier: containerID)
        let db = container.privateCloudDatabase
        // Subscription on *any* new MotionEvent record (predicate is
        // `TRUEPREDICATE` — we want every event). The notificationInfo
        // marks it as a silent push so iOS can wake the app
        // briefly without alerting the user (we post the local
        // notification ourselves from the fetched record, with the
        // user's local notification preferences applied).
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: MotionEvent.recordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKQuerySubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await db.save(subscription)
            log.info("Motion-event CKQuerySubscription installed")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // CloudKit returns this when the subscription already
            // exists. Treat as success.
            log.debug("Motion-event subscription already registered")
        } catch {
            log.warning("Subscription install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch a specific record after a silent push arrives. Returns
    /// the decoded `MotionEvent` (or nil if the record is gone or
    /// malformed). Callers feed the result back to
    /// `EventNotifier.notify(...)` to post the local notification.
    public func fetch(recordID: CKRecord.ID) async -> MotionEvent? {
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else {
            return nil
        }
        let container = CKContainer(identifier: containerID)
        let db = container.privateCloudDatabase
        do {
            let record = try await db.record(for: recordID)
            return MotionEvent(record: record)
        } catch {
            log.warning("Fetch motion event \(recordID.recordName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Lookup helper. The user's per-side opt-in lives in UserDefaults
/// so both Keychain.swift / EventNotifier / scenes can read it
/// without needing to plumb the value through.
public enum MotionEventRelaySettings {
    /// Master toggle for the macOS publisher. Off by default.
    public static let publisherEnabledKey = "com.reolens.cloudKitRelay.publisherEnabled"
    public static var publisherEnabled: Bool {
        UserDefaults.standard.bool(forKey: publisherEnabledKey)
    }
    /// Subscriber side. iOS only — `installSubscriptionIfNeeded` is
    /// gated on this so users who don't want CloudKit subscriptions
    /// (e.g. on cellular data with strict iCloud sync limits) can
    /// opt out. Default ON because the subscription is essentially
    /// free and harmless when no events arrive.
    public static let subscriberEnabledKey = "com.reolens.cloudKitRelay.subscriberEnabled"
    public static var subscriberEnabled: Bool {
        if UserDefaults.standard.object(forKey: subscriberEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: subscriberEnabledKey)
    }
}

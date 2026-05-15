import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.Reolens", category: "NotificationHistory")

/// A single record in the user-facing notification log.
///
/// Captures the full story of one motion notification: the camera + AI
/// classification that produced it, the title/body actually shown,
/// what (if anything) blocked delivery, and (later) whether the user
/// tapped it.
///
/// Every field is optional or carries a default so this Codable
/// remains forward-stable. A 0.6.0 device reading a 0.7.0 file simply
/// ignores fields it doesn't know about; a 0.7.0 device reading a
/// 0.6.0 file decodes missing fields as their default.
public struct NotificationRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: Source
    public let cameraID: UUID
    public let channel: Int
    public let cameraName: String
    public let detectionTag: String?
    public let title: String
    public let body: String
    public let thumbnailRelativePath: String?
    public var deliveryStatus: DeliveryStatus
    public var tappedAt: Date?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        source: Source,
        cameraID: UUID,
        channel: Int,
        cameraName: String,
        detectionTag: String?,
        title: String,
        body: String,
        thumbnailRelativePath: String? = nil,
        deliveryStatus: DeliveryStatus = .posted,
        tappedAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.cameraID = cameraID
        self.channel = channel
        self.cameraName = cameraName
        self.detectionTag = detectionTag
        self.title = title
        self.body = body
        self.thumbnailRelativePath = thumbnailRelativePath
        self.deliveryStatus = deliveryStatus
        self.tappedAt = tappedAt
    }

    /// Where the notification was generated. The local path means
    /// `EventNotifier` composed it from a direct Baichuan event;
    /// `cloudKitSilentPush` means the iOS subscriber received a relayed
    /// event from another Apple device's publisher; `digest` is the
    /// overnight summary; `test` is the user-triggered diagnostic.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case local
        case cloudKitSilentPush
        case digest
        case test
    }

    /// What ultimately happened to this notification on the device.
    /// `posted` means it reached the user; the other cases are silent
    /// drops that the diagnostics view + log let users discover.
    public enum DeliveryStatus: String, Codable, Sendable, CaseIterable {
        case posted
        case throttledCooldown
        case permissionDenied
        case perCameraMuted
        case tagMuted
        case motionMutedGlobally
        case aiMutedGlobally
        case globallyDisabled
        case failed
    }
}

// MARK: - Persistence wrapper

/// File-format wrapper. Versioned so 0.7 can detect a schema change
/// without silently losing data. New fields go into `NotificationRecord`
/// itself (Codable additive); a breaking format change bumps `version`
/// and adds a migration closure.
struct NotificationHistoryFile: Codable, Sendable {
    var version: Int
    var records: [NotificationRecord]

    static let currentVersion: Int = 1
}

// MARK: - Actor

/// File-backed actor storing the rolling notification log.
///
/// Single JSON file in the App Group container (or a custom path for
/// tests). Newest-first; capped at 1,000 records by default. All
/// writes are atomic — we encode to a side path then rename — so a
/// crash mid-write can't truncate the log.
///
/// AGENTS.md §5: per-device, local-only. The log is never relayed
/// through CloudKit; the on-disk file lives in the user's own App
/// Group container.
public actor NotificationHistory {

    /// Default singleton wired to the App Group `notifications.v1.json`.
    /// If the App Group entitlement is missing (local `swift run`),
    /// `record(_:)` and `snapshot()` no-op silently — the log is
    /// only meaningful in a real signed build.
    public static let shared = NotificationHistory()

    private let storeURL: URL?
    private let cap: Int
    private var cache: [NotificationRecord]
    private var loaded: Bool = false

    public init(
        storeURL: URL? = NotificationHistory.defaultStoreURL(),
        cap: Int = 1_000
    ) {
        self.storeURL = storeURL
        self.cap = cap
        self.cache = []
    }

    public static func defaultStoreURL() -> URL? {
        SharedContainer.containerURL?.appending(path: "notifications.v1.json")
    }

    // MARK: - Read

    public func snapshot() -> [NotificationRecord] {
        ensureLoaded()
        return cache
    }

    /// Snapshot filtered + sorted for the UI. Reverse-chronological by
    /// timestamp (newest first), with optional camera / tag / status
    /// filters applied before paging.
    public func query(
        cameraID: UUID? = nil,
        detectionTag: String? = nil,
        deliveryStatus: NotificationRecord.DeliveryStatus? = nil,
        limit: Int? = nil
    ) -> [NotificationRecord] {
        ensureLoaded()
        var items = cache
        if let cameraID { items = items.filter { $0.cameraID == cameraID } }
        if let detectionTag { items = items.filter { $0.detectionTag == detectionTag } }
        if let deliveryStatus { items = items.filter { $0.deliveryStatus == deliveryStatus } }
        if let limit { items = Array(items.prefix(limit)) }
        return items
    }

    // MARK: - Write

    /// Insert a new record at the head (newest-first). Trims to `cap`
    /// and persists atomically.
    public func record(_ record: NotificationRecord) {
        ensureLoaded()
        cache.insert(record, at: 0)
        if cache.count > cap {
            cache = Array(cache.prefix(cap))
        }
        persist()
    }

    /// Mark a record as tapped. Used by `NotificationTapDelegate` so
    /// the log can show whether the user actually engaged with each
    /// notification. Matches by record id (which we set as the
    /// `UNNotificationRequest.identifier` so we have a stable handle).
    /// No-op when the id isn't in the log (it scrolled off the cap or
    /// was already cleared).
    public func markTapped(id: UUID, at when: Date = Date()) {
        ensureLoaded()
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].tappedAt = when
        persist()
    }

    /// Wipe the log. Called from the user-facing "Clear all" button
    /// and from unit tests.
    public func clear() {
        ensureLoaded()
        cache.removeAll()
        persist()
    }

    // MARK: - Lazy load

    /// Lazy-read on first access. Keeps construction cheap (no disk IO
    /// in `init`) and lets the actor adopt the storeURL after init for
    /// tests.
    ///
    /// 0.6.2 — read / decode failures now route through
    /// `AppErrorRecorder` (category `.persistence`) so a corrupted
    /// notification log shows up in Diagnostics Center rather than
    /// presenting as a mysteriously-empty history when the user is
    /// trying to assemble a support thread.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("Failed to read notification history: \(error.localizedDescription, privacy: .public)")
            Task {
                await AppErrorRecorder.shared.record(
                    .persistence(.read(path: url.lastPathComponent)),
                    context: "notificationHistory.read"
                )
            }
            return
        }
        let file: NotificationHistoryFile
        do {
            file = try Self.decoder.decode(NotificationHistoryFile.self, from: data)
        } catch {
            log.warning("Failed to decode notification history; starting fresh")
            Task {
                await AppErrorRecorder.shared.record(
                    .persistence(.decode(reason: String(describing: error))),
                    context: "notificationHistory.decode"
                )
            }
            return
        }
        guard file.version == NotificationHistoryFile.currentVersion else {
            log.notice("Notification history schema version \(file.version) — current is \(NotificationHistoryFile.currentVersion). No migration available; starting fresh.")
            return
        }
        cache = file.records
    }

    private func persist() {
        guard let url = storeURL else { return }
        let file = NotificationHistoryFile(
            version: NotificationHistoryFile.currentVersion,
            records: cache
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(file)
            // Atomic write — `.atomic` writes to a side path then
            // renames, so a crash mid-write can't truncate the log.
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to persist notification history: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Codable plumbing

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "shared-container")

/// Device-local shared App-Group container, used by the main app to publish
/// the snapshot + recent-event metadata that the WidgetKit extension and the
/// in-flight motion-event Live Activity read.
///
/// All reads and writes go through this type — no widget or activity
/// extension ever opens a CloudKit container, talks to a camera, or touches
/// the Keychain. AGENTS.md §5 (no telemetry, no remote storage) and §16
/// (widgets + Live Activities) state the invariants this type enforces.
public enum SharedContainer {

    public static let groupIdentifier = "group.com.reolens.Reolens"

    // MARK: - Locations

    /// Root of the App-Group container, or `nil` if entitlements are missing
    /// (which happens on ad-hoc / dev builds without the App-Group entry —
    /// see [App/Reolens.dev.entitlements] for the carve-out).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// `LatestSnapshots.plist` — array of `LatestSnapshot` records.
    public static var snapshotsURL: URL? { containerURL?.appending(path: "LatestSnapshots.plist") }

    /// `RecentMotionEvents.plist` — capped array of `RecentMotionEvent`s.
    public static var eventsURL: URL? { containerURL?.appending(path: "RecentMotionEvents.plist") }

    /// Directory `digests/` — one `<yyyy-MM-dd>.json` per day.
    public static var digestsDirectory: URL? { containerURL?.appending(path: "digests") }

    /// Directory `snapshots/` — small jpegs keyed by camera UUID for widget reads.
    public static var snapshotImagesDirectory: URL? { containerURL?.appending(path: "snapshots") }

    /// Directory `activity-assets/` — per-Live-Activity trigger-frame jpegs,
    /// purged at 4 h or on activity dismiss. AGENTS.md §16: frames never
    /// leave the device.
    public static var activityAssetsDirectory: URL? { containerURL?.appending(path: "activity-assets") }

    // MARK: - Records

    public struct LatestSnapshot: Codable, Sendable, Hashable {
        public let cameraID: UUID
        public let channel: Int
        public let cameraName: String
        public let lastUpdated: Date
        public let imageRelativePath: String?   // relative to `snapshotImagesDirectory`
        public let lastMotionAt: Date?

        public init(
            cameraID: UUID,
            channel: Int,
            cameraName: String,
            lastUpdated: Date,
            imageRelativePath: String?,
            lastMotionAt: Date?
        ) {
            self.cameraID = cameraID
            self.channel = channel
            self.cameraName = cameraName
            self.lastUpdated = lastUpdated
            self.imageRelativePath = imageRelativePath
            self.lastMotionAt = lastMotionAt
        }
    }

    public struct RecentMotionEvent: Codable, Sendable, Hashable {
        public let id: UUID
        public let cameraID: UUID
        public let channel: Int
        public let cameraName: String
        public let timestamp: Date
        public let aiTags: [String]
        public let triggerFrameRelativePath: String?

        public init(
            id: UUID,
            cameraID: UUID,
            channel: Int,
            cameraName: String,
            timestamp: Date,
            aiTags: [String],
            triggerFrameRelativePath: String?
        ) {
            self.id = id
            self.cameraID = cameraID
            self.channel = channel
            self.cameraName = cameraName
            self.timestamp = timestamp
            self.aiTags = aiTags
            self.triggerFrameRelativePath = triggerFrameRelativePath
        }
    }

    public struct DailyDigestRecord: Codable, Sendable, Hashable {
        /// Local midnight of the *day being summarized*.
        public let day: Date
        public let totalEvents: Int
        public let perCameraCounts: [PerCameraCount]
        public let perTagCounts: [String: Int]
        public let peakHour: Int
        /// 24-entry hourly histogram (index 0 = 00:00 local hour).
        public let hourlyBuckets: [Int]

        public init(
            day: Date,
            totalEvents: Int,
            perCameraCounts: [PerCameraCount],
            perTagCounts: [String: Int],
            peakHour: Int,
            hourlyBuckets: [Int]
        ) {
            self.day = day
            self.totalEvents = totalEvents
            self.perCameraCounts = perCameraCounts
            self.perTagCounts = perTagCounts
            self.peakHour = peakHour
            self.hourlyBuckets = hourlyBuckets
        }

        public struct PerCameraCount: Codable, Sendable, Hashable {
            public let cameraName: String
            public let count: Int
            public init(cameraName: String, count: Int) {
                self.cameraName = cameraName
                self.count = count
            }
        }
    }

    // MARK: - Snapshot list

    public static func writeLatestSnapshots(_ snapshots: [LatestSnapshot]) throws {
        guard let url = snapshotsURL else { return }
        try ensureContainerLayout()
        let data = try Self.plistEncoder.encode(snapshots)
        try data.write(to: url, options: .atomic)
    }

    public static func readLatestSnapshots() -> [LatestSnapshot] {
        // safe: widget surface — empty fallback is the right UX. Bad
        // bytes get overwritten by the next successful main-app write.
        guard let url = snapshotsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.plistDecoder.decode([LatestSnapshot].self, from: data)) ?? []
    }

    public static func writeSnapshotImage(cameraID: UUID, channel: Int, jpegData: Data) throws -> String {
        guard let dir = snapshotImagesDirectory else { return "" }
        try ensureContainerLayout()
        let filename = "\(cameraID.uuidString)_ch\(channel).jpg"
        let url = dir.appending(path: filename)
        try jpegData.write(to: url, options: .atomic)
        return filename
    }

    // MARK: - Recent motion events

    /// Append an event and rotate the file to keep at most `cap` entries
    /// (newest-first). Inside `EventNotifier` we call this on every motion
    /// fire so widgets stay fresh without re-querying.
    public static func appendMotionEvent(_ event: RecentMotionEvent, cap: Int = 50) throws {
        guard let url = eventsURL else { return }
        try ensureContainerLayout()
        var existing: [RecentMotionEvent] = []
        // safe: append path — corrupt prior contents are implicitly
        // recovered by the next write (we re-emit the full array).
        if let data = try? Data(contentsOf: url) {
            existing = (try? Self.plistDecoder.decode([RecentMotionEvent].self, from: data)) ?? []
        }
        existing.insert(event, at: 0)
        if existing.count > cap { existing = Array(existing.prefix(cap)) }
        let data = try Self.plistEncoder.encode(existing)
        try data.write(to: url, options: .atomic)
    }

    public static func readRecentMotionEvents() -> [RecentMotionEvent] {
        // safe: widget surface — empty fallback is the right UX. Bad
        // bytes get overwritten by the next successful main-app write.
        guard let url = eventsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.plistDecoder.decode([RecentMotionEvent].self, from: data)) ?? []
    }

    // MARK: - Daily digests

    public static func writeDailyDigest(_ digest: DailyDigestRecord) throws {
        guard let dir = digestsDirectory else { return }
        try ensureContainerLayout()
        let filename = Self.digestFilename(for: digest.day)
        let url = dir.appending(path: filename)
        let data = try Self.jsonEncoder.encode(digest)
        try data.write(to: url, options: .atomic)
        // Cap to ~30 days. Iterate, sort by name (yyyy-MM-dd sorts
        // lexicographically), delete excess.
        try pruneDigests(keeping: 30)
    }

    public static func readMostRecentDigest() -> DailyDigestRecord? {
        guard let dir = digestsDirectory else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let sorted = names.sorted().reversed()
        for name in sorted {
            let url = dir.appending(path: name)
            if let data = try? Data(contentsOf: url),
               let digest = try? Self.jsonDecoder.decode(DailyDigestRecord.self, from: data) {
                return digest
            }
        }
        return nil
    }

    static func digestFilename(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day) + ".json"
    }

    private static func pruneDigests(keeping max: Int) throws {
        guard let dir = digestsDirectory else { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let sorted = names.sorted()  // ascending — oldest first
        if sorted.count <= max { return }
        let excess = sorted.prefix(sorted.count - max)
        for name in excess {
            try? fm.removeItem(at: dir.appending(path: name))
        }
    }

    // MARK: - Live-Activity assets

    /// Write a JPEG to `activity-assets/<eventID>.jpg` and return the file URL.
    /// Frames are purged by `purgeStaleActivityAssets` at the activity's
    /// auto-dismiss boundary so a flood of motion events doesn't grow the
    /// container unbounded.
    public static func writeActivityFrame(eventID: UUID, jpegData: Data) throws -> URL? {
        guard let dir = activityAssetsDirectory else { return nil }
        try ensureContainerLayout()
        let url = dir.appending(path: "\(eventID.uuidString).jpg")
        try jpegData.write(to: url, options: .atomic)
        return url
    }

    public static func purgeStaleActivityAssets(olderThan ttlSeconds: TimeInterval = 4 * 60 * 60) {
        guard let dir = activityAssetsDirectory else { return }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-ttlSeconds)
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantFuture
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals

    private static let plistEncoder: PropertyListEncoder = {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }()

    private static let plistDecoder = PropertyListDecoder()

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func ensureContainerLayout() throws {
        let fm = FileManager.default
        for dir in [snapshotImagesDirectory, activityAssetsDirectory, digestsDirectory] {
            guard let dir else { continue }
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}

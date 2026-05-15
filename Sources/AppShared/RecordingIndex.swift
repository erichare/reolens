import Foundation
import OSLog
import ReolinkAPI
import ReolinkBaichuan

private let log = Logger(subsystem: "com.reolens.app", category: "recording-index")

/// 0.6.0 — Cross-day index of recording metadata.
///
/// Indexes the last `retentionDays` days of recordings so the user can
/// run cross-day queries — "all packages this week", "vehicles between
/// these hours" — without hammering the hub with re-Searches. The
/// `RecordingsLoader` and `AllRecordingsLoader` feed this actor as a
/// side-effect of their normal work: no new network traffic is required
/// to populate the index; we just store what's already been fetched.
///
/// Schema deliberately small (`IndexedRecording`) so the file stays
/// tractable even with many channels × 30 days × dozens of recordings/day.
/// 30 cameras × 30 days × 200 recordings ≈ 180,000 rows × ~120 bytes ≈
/// ~22 MB — well within disk budget but enough that we keep an in-memory
/// `[DayKey: [IndexedRecording]]` cache to avoid linear scans.
///
/// Follows the same persistence shape as `NotificationHistory`:
/// versioned JSON file in the App Group container, lazy-load on first
/// access, atomic write via `.atomic` data-write.
public actor RecordingIndex {

    /// Default singleton wired to `recording-index.v1.json` in the App
    /// Group container.
    public static let shared = RecordingIndex()

    // MARK: - Public types

    /// One indexed recording row. Aggregates the CGI `Search` and the
    /// Baichuan `findAlarmVideo` views of the same underlying file —
    /// `detectionTags` is the union of both sources, so a query for
    /// `.person` matches whether the tag came from CGI or Baichuan.
    public struct IndexedRecording: Codable, Sendable, Hashable, Identifiable {
        public let cameraID: UUID
        public let cameraName: String
        public let channel: Int
        public let fileName: String
        public let start: Date
        public let end: Date
        public let detectionTags: Set<DetectionType>
        public let source: Source
        public var hasBookmark: Bool

        /// Composite id — `fileName` alone collides across channels.
        public var id: String {
            "\(cameraID.uuidString):\(channel):\(fileName)"
        }

        public enum Source: String, Codable, Sendable {
            case cgiSearch
            case findAlarmVideo
            case both
        }

        public init(
            cameraID: UUID,
            cameraName: String,
            channel: Int,
            fileName: String,
            start: Date,
            end: Date,
            detectionTags: Set<DetectionType>,
            source: Source,
            hasBookmark: Bool = false
        ) {
            self.cameraID = cameraID
            self.cameraName = cameraName
            self.channel = channel
            self.fileName = fileName
            self.start = start
            self.end = end
            self.detectionTags = detectionTags
            self.source = source
            self.hasBookmark = hasBookmark
        }
    }

    /// Query parameters. All optional + composable. An empty query
    /// returns every indexed recording (capped at `limit`).
    public struct Query: Sendable, Equatable {
        public var tagFilter: Set<DetectionType>
        public var dateRange: ClosedRange<Date>?
        public var cameraIDs: Set<UUID>
        public var limit: Int?

        public init(
            tagFilter: Set<DetectionType> = [],
            dateRange: ClosedRange<Date>? = nil,
            cameraIDs: Set<UUID> = [],
            limit: Int? = nil
        ) {
            self.tagFilter = tagFilter
            self.dateRange = dateRange
            self.cameraIDs = cameraIDs
            self.limit = limit
        }
    }

    // MARK: - State

    private let storeURL: URL?
    private let retentionDays: Int
    /// In-memory cache. Keyed by start-of-day so per-day refills are
    /// trivially indexable. Each entry's value is a flat array of all
    /// indexed recordings for that day.
    private var byDay: [Date: [IndexedRecording]] = [:]
    private var loaded: Bool = false

    public init(
        storeURL: URL? = RecordingIndex.defaultStoreURL(),
        retentionDays: Int = 30
    ) {
        self.storeURL = storeURL
        self.retentionDays = retentionDays
    }

    public static func defaultStoreURL() -> URL? {
        SharedContainer.containerURL?.appending(path: "recording-index.v1.json")
    }

    // MARK: - Ingestion

    /// Ingest a batch of CGI `Search` results for one (camera, day).
    /// **Idempotent**: re-ingesting the same camera+day replaces only
    /// that camera's entries — other cameras' entries for the same day
    /// are untouched. Use the `BaichuanAlarmVideoFile` overload to
    /// enrich existing entries with AI tags.
    public func ingest(
        _ files: [SearchFile],
        cameraID: UUID,
        cameraName: String,
        channel: Int,
        day: Date
    ) {
        ensureLoaded()
        let dayKey = Calendar.current.startOfDay(for: day)
        var existing = byDay[dayKey] ?? []
        // Remove this camera+channel's prior entries for the day so
        // re-ingestion doesn't double-count.
        existing.removeAll { $0.cameraID == cameraID && $0.channel == channel }

        for file in files {
            guard let start = file.startDate, let end = file.endDate else { continue }
            let row = IndexedRecording(
                cameraID: cameraID,
                cameraName: cameraName,
                channel: channel,
                fileName: file.name,
                start: start,
                end: end,
                detectionTags: Set(file.triggers),
                source: .cgiSearch
            )
            existing.append(row)
        }
        byDay[dayKey] = existing
        purgeOldDays()
        persist()
    }

    /// Merge Baichuan alarm-video AI tags into existing CGI Search
    /// entries for the same (camera, day). Matching is by filename
    /// first, then by time-range overlap — mirrors the loader's
    /// three-tier `effectiveDetections` pipeline. Idempotent.
    public func mergeAlarmVideos(
        _ alarmVideos: [BaichuanAlarmVideoFile],
        cameraID: UUID,
        channel: Int,
        day: Date
    ) {
        ensureLoaded()
        let dayKey = Calendar.current.startOfDay(for: day)
        guard var rows = byDay[dayKey], !rows.isEmpty else {
            // Nothing to merge into yet — Baichuan landed before CGI.
            // The next `ingest(_:cameraID:channel:day:)` will re-trigger
            // tag attribution via the loader, so dropping here is safe.
            return
        }
        var changed = false
        for i in rows.indices where rows[i].cameraID == cameraID && rows[i].channel == channel {
            let row = rows[i]
            let matches = alarmVideos.filter { av in
                if av.fileName == row.fileName { return true }
                guard let avStart = av.startDate, let avEnd = av.endDate else { return false }
                return avStart < row.end && avEnd > row.start
            }
            guard !matches.isEmpty else { continue }
            var tags = row.detectionTags
            for av in matches {
                tags.formUnion(av.detections)
            }
            if tags != row.detectionTags {
                rows[i] = IndexedRecording(
                    cameraID: row.cameraID,
                    cameraName: row.cameraName,
                    channel: row.channel,
                    fileName: row.fileName,
                    start: row.start,
                    end: row.end,
                    detectionTags: tags,
                    source: row.source == .cgiSearch ? .both : row.source,
                    hasBookmark: row.hasBookmark
                )
                changed = true
            }
        }
        if changed {
            byDay[dayKey] = rows
            persist()
        }
    }

    // MARK: - Queries

    /// Run a query. Empty filters → "everything within retention".
    /// Returns newest-first, capped at `limit` if specified.
    public func query(_ q: Query = Query()) -> [IndexedRecording] {
        ensureLoaded()
        let days = relevantDays(for: q.dateRange)
        var results: [IndexedRecording] = []
        for day in days {
            guard let rows = byDay[day] else { continue }
            for row in rows where matches(row, query: q) {
                results.append(row)
            }
        }
        results.sort { $0.start > $1.start }
        if let limit = q.limit { results = Array(results.prefix(limit)) }
        return results
    }

    private func relevantDays(for range: ClosedRange<Date>?) -> [Date] {
        guard let range else {
            return byDay.keys.sorted(by: >)
        }
        let cal = Calendar.current
        let lo = cal.startOfDay(for: range.lowerBound)
        let hi = cal.startOfDay(for: range.upperBound)
        return byDay.keys
            .filter { $0 >= lo && $0 <= hi }
            .sorted(by: >)
    }

    private func matches(_ row: IndexedRecording, query: Query) -> Bool {
        if !query.tagFilter.isEmpty,
           row.detectionTags.intersection(query.tagFilter).isEmpty {
            return false
        }
        if !query.cameraIDs.isEmpty, !query.cameraIDs.contains(row.cameraID) {
            return false
        }
        if let range = query.dateRange {
            if row.start < range.lowerBound || row.start > range.upperBound {
                return false
            }
        }
        return true
    }

    /// Total row count across all indexed days. Mainly for telemetry +
    /// the "Index now" button's progress display.
    public func count() -> Int {
        ensureLoaded()
        return byDay.values.reduce(0) { $0 + $1.count }
    }

    /// Days currently indexed, newest-first. Useful for the index-
    /// status section in Settings.
    public func indexedDays() -> [Date] {
        ensureLoaded()
        return byDay.keys.sorted(by: >)
    }

    /// Wipe the index. Test + user-facing "Reset index" hook.
    public func clear() {
        ensureLoaded()
        byDay.removeAll()
        persist()
    }

    /// Mark a recording as bookmarked. Called from the bookmark store
    /// so the search results can show a bookmark chip without a join.
    public func setBookmark(
        cameraID: UUID,
        channel: Int,
        fileName: String,
        hasBookmark: Bool
    ) {
        ensureLoaded()
        var changed = false
        for (day, rows) in byDay {
            var updated = rows
            for i in updated.indices
                where updated[i].cameraID == cameraID
                    && updated[i].channel == channel
                    && updated[i].fileName == fileName {
                if updated[i].hasBookmark != hasBookmark {
                    updated[i].hasBookmark = hasBookmark
                    changed = true
                }
            }
            if changed { byDay[day] = updated }
        }
        if changed { persist() }
    }

    // MARK: - Persistence

    private func purgeOldDays() {
        let cutoff = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-Double(retentionDays * 86_400))
        )
        let removed = byDay.keys.filter { $0 < cutoff }
        for day in removed { byDay.removeValue(forKey: day) }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return
        }
        let file: RecordingIndexFile
        do {
            file = try Self.decoder.decode(RecordingIndexFile.self, from: data)
        } catch {
            log.warning("Failed to decode recording index; starting fresh")
            // 0.6.1 — surface index corruption through AppErrorRecorder
            // so the user can discover from Diagnostics Center why
            // their recordings disappeared briefly after launch.
            // 0.6.1 M-2 — cap the decoder description at 120 chars so
            // a malformed file with very long key paths doesn't bloat
            // a single log record.
            let reason = String(error.localizedDescription.prefix(120))
            AppErrorRecorder.recordAsync(
                .persistence(.decode(reason: "recording-index.v1.json: \(reason)")),
                context: "recordingIndex.load"
            )
            return
        }
        guard file.version == RecordingIndexFile.currentVersion else {
            log.notice("Recording index schema version \(file.version) — current is \(RecordingIndexFile.currentVersion). No migration available; starting fresh.")
            return
        }
        for row in file.rows {
            let day = Calendar.current.startOfDay(for: row.start)
            byDay[day, default: []].append(row)
        }
        purgeOldDays()
    }

    private func persist() {
        guard let url = storeURL else { return }
        let rows = byDay.values.flatMap { $0 }
        let file = RecordingIndexFile(
            version: RecordingIndexFile.currentVersion,
            rows: rows
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to persist recording index: \(error.localizedDescription, privacy: .public)")
        }
    }

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

// MARK: - File format

/// Versioned on-disk envelope. Bumping `currentVersion` plus adding a
/// migration closure handles breaking schema changes; additive field
/// changes don't require a bump because `IndexedRecording` is Codable
/// with defaults.
struct RecordingIndexFile: Codable, Sendable {
    var version: Int
    var rows: [RecordingIndex.IndexedRecording]

    static let currentVersion: Int = 1
}

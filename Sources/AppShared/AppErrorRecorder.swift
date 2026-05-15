import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.Reolens", category: "AppErrorRecorder")

/// A single record in the local error log. Mirrors `NotificationRecord`
/// in shape and persistence posture — file-backed in the App Group
/// container, never relayed to a server.
///
/// `category` is the stable on-disk tag (additive only; never rename).
/// `detail` is a short developer-facing string; `userMessage` is the
/// short user-facing copy if the error was surfaced in UI. `context`
/// is the optional call-site hint passed by `record(_:context:)` —
/// useful for grouping ("settings.saveSchedule", "ingest.recording").
///
/// New in 0.6.1.
public struct AppErrorRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let category: AppError.Category
    public let detail: String
    public let userMessage: String?
    public let context: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AppError.Category,
        detail: String,
        userMessage: String? = nil,
        context: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.detail = detail
        self.userMessage = userMessage
        self.context = context
    }
}

// MARK: - Persistence wrapper

struct AppErrorFile: Codable, Sendable {
    var version: Int
    var records: [AppErrorRecord]

    static let currentVersion: Int = 1
}

// MARK: - Actor

/// File-backed actor storing the rolling error log.
///
/// Singleton wired to `app-errors.v1.json` in the App Group container.
/// Newest-first; capped at 500 records (smaller than the notification
/// log because error volume should stay low — a flood is itself a
/// signal). Atomic writes. AGENTS.md §5 — device-local only.
///
/// New in 0.6.1.
public actor AppErrorRecorder {

    public static let shared = AppErrorRecorder()

    private let storeURL: URL?
    private let cap: Int
    private var cache: [AppErrorRecord]
    private var loaded: Bool = false

    public init(
        storeURL: URL? = AppErrorRecorder.defaultStoreURL(),
        cap: Int = 500
    ) {
        self.storeURL = storeURL
        self.cap = cap
        self.cache = []
    }

    public static func defaultStoreURL() -> URL? {
        SharedContainer.containerURL?.appending(path: "app-errors.v1.json")
    }

    // MARK: - Write

    /// Record a typed error. `context` is an optional short tag for
    /// grouping ("settings.saveSchedule", "ingest.recording"). The
    /// `AppError.errorDescription` is captured as the userMessage if
    /// one is defined; the `description` is always captured as detail.
    public func record(_ error: AppError, context: String? = nil) {
        let record = AppErrorRecord(
            category: error.category,
            detail: error.description,
            userMessage: error.errorDescription,
            context: context
        )
        insert(record)
    }

    /// Lower-level entry for callers that already have an
    /// `AppErrorRecord` (tests, replays, or batched ingestion).
    public func record(_ record: AppErrorRecord) {
        insert(record)
    }

    private func insert(_ record: AppErrorRecord) {
        ensureLoaded()
        cache.insert(record, at: 0)
        if cache.count > cap {
            cache = Array(cache.prefix(cap))
        }
        persist()
    }

    // MARK: - Read

    public func snapshot() -> [AppErrorRecord] {
        ensureLoaded()
        return cache
    }

    /// Filtered snapshot for the UI. Reverse-chronological by
    /// timestamp.
    public func query(
        category: AppError.Category? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) -> [AppErrorRecord] {
        ensureLoaded()
        var items = cache
        if let category { items = items.filter { $0.category == category } }
        if let since { items = items.filter { $0.timestamp >= since } }
        if let limit { items = Array(items.prefix(limit)) }
        return items
    }

    /// Tally of records per category. Cheap to compute since `cache`
    /// is bounded by `cap`. Used by the diagnostics summary header.
    public func counts() -> [AppError.Category: Int] {
        ensureLoaded()
        var result: [AppError.Category: Int] = [:]
        for record in cache {
            result[record.category, default: 0] += 1
        }
        return result
    }

    public func clear() {
        ensureLoaded()
        cache.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return
        }
        guard let file = try? Self.decoder.decode(AppErrorFile.self, from: data) else {
            log.warning("Failed to decode app-errors log; starting fresh")
            return
        }
        guard file.version == AppErrorFile.currentVersion else {
            log.notice("App-errors schema version \(file.version) — current is \(AppErrorFile.currentVersion). Starting fresh.")
            return
        }
        cache = file.records
    }

    private func persist() {
        guard let url = storeURL else { return }
        let file = AppErrorFile(
            version: AppErrorFile.currentVersion,
            records: cache
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to persist app-errors log: \(error.localizedDescription, privacy: .public)")
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

// MARK: - Convenience

public extension AppErrorRecorder {
    /// Fire-and-forget recording from a synchronous call site. Spawns
    /// a detached task so the call site doesn't pay for actor hop +
    /// disk write. Use when the call site can't `await` directly —
    /// e.g. a view body, a non-async delegate.
    ///
    /// **Ordering caveat (0.6.1 L-1):** two concurrent `recordAsync`
    /// calls from different call sites can arrive at the actor in a
    /// different order than they were fired. Acceptable for an audit
    /// log (timestamps still come from the underlying `record(_:)`
    /// at insertion time, so cross-record ordering is preserved by
    /// `timestamp`, just not by insertion position in `cache`).
    nonisolated static func recordAsync(_ error: AppError, context: String? = nil) {
        Task.detached(priority: .utility) {
            await AppErrorRecorder.shared.record(error, context: context)
        }
    }
}

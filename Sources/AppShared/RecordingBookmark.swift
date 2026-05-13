import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "bookmarks")

/// User-saved bookmark pointing at a specific moment in a camera's
/// recording. Bookmarks live as references — no media is ever
/// uploaded to iCloud, just the time range and an optional note.
///
/// Cross-device sync: the bookmark JSON sits in the iCloud Drive
/// ubiquity container alongside `cameras.json`. AGENTS.md §4 (no
/// credentials in sync), §7 (forward-compatible schema — bump to
/// `_v2` if any field needs to change).
public struct RecordingBookmark: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public let cameraID: UUID
    public let channel: Int
    public let startEpoch: TimeInterval
    public let endEpoch: TimeInterval
    public let note: String?
    public let aiTagsAtMark: [String]
    /// Schema-version marker per AGENTS.md §7. Always `1` for the
    /// initial release; bump in a future minor version to introduce
    /// breaking field changes alongside a `bookmarks_v2.json` file.
    public let schemaVersion: Int

    public init(
        id: UUID = UUID(),
        cameraID: UUID,
        channel: Int,
        startEpoch: TimeInterval,
        endEpoch: TimeInterval,
        note: String? = nil,
        aiTagsAtMark: [String] = [],
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.cameraID = cameraID
        self.channel = channel
        self.startEpoch = startEpoch
        self.endEpoch = endEpoch
        self.note = note
        self.aiTagsAtMark = aiTagsAtMark
        self.schemaVersion = schemaVersion
    }

    public var startDate: Date { Date(timeIntervalSince1970: startEpoch) }
    public var endDate: Date { Date(timeIntervalSince1970: endEpoch) }
    public var duration: TimeInterval { endEpoch - startEpoch }
    /// 0.5.0 Theme C1 — closed range used by the export pipeline.
    /// The clip exporter consumes per-source-relative ranges; callers
    /// subtract the source file's start epoch before passing this in.
    public var range: ClosedRange<TimeInterval> {
        let lo = min(startEpoch, endEpoch)
        let hi = max(startEpoch, endEpoch)
        return lo...hi
    }
}

/// Persistence façade. Stores per-camera bookmark lists at
/// `bookmarks_v1.json` files inside the iCloud Drive container, with
/// a local-only fallback under the user's Documents directory when
/// iCloud isn't reachable. AGENTS.md §7: read accepts unknown
/// fields silently; write preserves them.
public enum RecordingBookmarkStore {

    /// Mirror of `ICloudCameraStorage`'s ubiquity-container lookup —
    /// reusing the same pattern keeps the layout consistent.
    private static var rootDirectory: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.reolens.Reolens")?
            .appending(path: "Documents/bookmarks")
    }

    private static var localFallback: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appending(path: "Reolens/bookmarks")
    }

    public static func bookmarksURL(for cameraID: UUID) -> URL {
        let base = rootDirectory ?? localFallback
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "\(cameraID.uuidString)-bookmarks_v1.json")
    }

    public static func read(cameraID: UUID) -> [RecordingBookmark] {
        let url = bookmarksURL(for: cameraID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingBookmark].self, from: data)) ?? []
    }

    public static func write(_ bookmarks: [RecordingBookmark], for cameraID: UUID) throws {
        let url = bookmarksURL(for: cameraID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bookmarks)
        try data.write(to: url, options: .atomic)
    }

    /// Convenience: append a bookmark to the camera's list.
    public static func add(_ bookmark: RecordingBookmark) throws {
        var existing = read(cameraID: bookmark.cameraID)
        existing.append(bookmark)
        try write(existing, for: bookmark.cameraID)
    }

    /// Convenience: delete a bookmark by ID.
    public static func remove(id: UUID, cameraID: UUID) throws {
        var existing = read(cameraID: cameraID)
        existing.removeAll { $0.id == id }
        try write(existing, for: cameraID)
    }
}

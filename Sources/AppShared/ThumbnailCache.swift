import Foundation
import OSLog
import CryptoKit

private let log = Logger(subsystem: "com.reolens.app", category: "thumbcache")

/// Content-addressed JPEG thumbnail cache for the recording scrubber
/// phase 2 (Theme A3). Entries live under
/// `~/Library/Caches/Reolens/thumbs/`; the cache caps at 500 MB with
/// last-access LRU eviction.
///
/// Reads are synchronous (file system, cheap). Writes are
/// asynchronous through a dispatch-serialized actor so an LRU
/// recompute can't race a new write. The cache is intentionally
/// dumb: it doesn't fetch frames itself — callers supply the JPEG
/// data they extracted with `AVAssetImageGenerator`.
public actor ThumbnailCache {

    public static let shared = ThumbnailCache()

    /// Default cap of 500 MB matches the planning doc.
    private let capacityBytes: UInt64
    private let directory: URL

    public init(capacityBytes: UInt64 = 500 * 1024 * 1024) {
        self.capacityBytes = capacityBytes
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appending(path: "Reolens/thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    /// Build a deterministic filename for a (segment, offset) pair so
    /// repeated extractions of the same point produce the same file.
    private static func filename(segmentID: String, offsetSeconds: Int) -> String {
        let canonical = "\(segmentID)|\(offsetSeconds)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // 16-char prefix; 256-bit hash truncated, still ample collision
        // resistance for the cardinality (≤ 50k entries per cache).
        return String(hex.prefix(16)) + ".jpg"
    }

    /// Path that *would* hold the thumbnail for this (segment, offset),
    /// whether or not the file actually exists.
    public func url(segmentID: String, offsetSeconds: Int) -> URL {
        directory.appending(path: Self.filename(segmentID: segmentID, offsetSeconds: offsetSeconds))
    }

    public func read(segmentID: String, offsetSeconds: Int) -> Data? {
        let path = url(segmentID: segmentID, offsetSeconds: offsetSeconds).path
        if FileManager.default.fileExists(atPath: path) {
            // Touch the file so LRU eviction sees it as recently used.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
    }

    public func write(segmentID: String, offsetSeconds: Int, jpegData: Data) {
        let target = url(segmentID: segmentID, offsetSeconds: offsetSeconds)
        do {
            try jpegData.write(to: target, options: .atomic)
        } catch {
            log.warning("Thumb write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        evictIfNeeded()
    }

    public func evictIfNeeded() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var entries: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? Date.distantPast
            entries.append((url, size, modified))
            total += size
        }
        if total <= capacityBytes { return }
        entries.sort { $0.modified < $1.modified }  // oldest first
        for entry in entries {
            if total <= capacityBytes { break }
            try? fm.removeItem(at: entry.url)
            total = total > entry.size ? total - entry.size : 0
        }
    }

    public func purgeAll() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? fm.removeItem(at: url)
        }
    }
}

/// In-memory cross-segment seek model. Knows the day's segments and
/// answers "which segment + offset matches this wall-clock time?"
/// Used by the new `ScrubberView` to smoothly seek across segment
/// boundaries without dropping back to the original AVPlayerView.
public struct SegmentScrubModel: Sendable, Hashable {

    public struct Segment: Sendable, Hashable, Identifiable {
        public let id: String
        public let startsAt: Date
        public let endsAt: Date
        public init(id: String, startsAt: Date, endsAt: Date) {
            self.id = id
            self.startsAt = startsAt
            self.endsAt = endsAt
        }
        public var duration: TimeInterval { endsAt.timeIntervalSince(startsAt) }
    }

    public let segments: [Segment]
    public init(segments: [Segment]) {
        self.segments = segments.sorted { $0.startsAt < $1.startsAt }
    }

    /// Resolve a wall-clock instant to a (segment, offset) pair.
    /// Returns nil if `time` falls between segments (a gap).
    public func resolve(time: Date) -> (segment: Segment, offset: TimeInterval)? {
        for segment in segments where segment.startsAt <= time && time < segment.endsAt {
            return (segment, time.timeIntervalSince(segment.startsAt))
        }
        return nil
    }

    /// Find the closest segment within `proximity` of `time`, even
    /// across a gap — the scrubber "snap-on-release" UX.
    public func nearest(to time: Date, within proximity: TimeInterval = 90) -> Segment? {
        let candidates = segments.compactMap { segment -> (Segment, TimeInterval)? in
            if segment.startsAt <= time && time < segment.endsAt {
                return (segment, 0)
            }
            let distance = min(
                abs(time.timeIntervalSince(segment.startsAt)),
                abs(time.timeIntervalSince(segment.endsAt))
            )
            return distance <= proximity ? (segment, distance) : nil
        }
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    /// The segment immediately following `current` in playback order,
    /// or nil if `current` is the last segment in the day. Used for
    /// preroll of the next `AVPlayerItem` 500 ms before the boundary.
    public func successor(of current: Segment) -> Segment? {
        guard let index = segments.firstIndex(of: current), index + 1 < segments.count else { return nil }
        return segments[index + 1]
    }
}

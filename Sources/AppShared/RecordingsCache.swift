import Foundation

/// 0.5.1 — In-memory cache of cross-hub recording fetches, keyed by
/// (set of session IDs, day). Bookmark inclusion is independent of
/// recordings (always read live from `RecordingBookmarkStore`) so the
/// cache stores only the `[ScopedRecording]` side.
///
/// Freshness policy:
/// - Today's data: 30-second TTL — recordings genuinely accrue as the
///   day goes on, so refetch frequently enough that the user doesn't
///   miss the just-arrived clip.
/// - Past days: 1-hour TTL — past days are effectively immutable
///   (the hub doesn't backfill), so cache aggressively.
///
/// "Cached but stale" entries are still returned from `get(...)` so
/// the view can paint them immediately while a fresh fetch runs in
/// the background — the caller decides whether to trigger a refresh
/// based on the returned `isStale` flag.
public actor RecordingsCache {
    public static let shared = RecordingsCache()

    public struct Entry: Sendable {
        public let rows: [ScopedRecording]
        public let cachedAt: Date
        public let isStale: Bool
    }

    private struct Key: Hashable {
        let sessionIDs: Set<UUID>
        let dayStart: Date
    }

    private var entries: [Key: (rows: [ScopedRecording], at: Date)] = [:]

    public init() {}

    /// Read a cache entry. Returns nil only when no entry exists at
    /// all; a stale entry is still returned with `isStale = true` so
    /// callers can paint it immediately and refresh in the background.
    public func get(sessionIDs: Set<UUID>, day: Date) -> Entry? {
        let key = Key(sessionIDs: sessionIDs, dayStart: Calendar.current.startOfDay(for: day))
        guard let cached = entries[key] else { return nil }
        let ttl = Self.ttl(for: key.dayStart)
        let isStale = Date().timeIntervalSince(cached.at) > ttl
        return Entry(rows: cached.rows, cachedAt: cached.at, isStale: isStale)
    }

    public func set(sessionIDs: Set<UUID>, day: Date, rows: [ScopedRecording]) {
        let key = Key(sessionIDs: sessionIDs, dayStart: Calendar.current.startOfDay(for: day))
        entries[key] = (rows: rows, at: Date())
    }

    /// Drop a specific (sessions, day) entry. Used when the user
    /// invokes a refresh action so the next load is forced to refetch.
    public func invalidate(sessionIDs: Set<UUID>, day: Date) {
        let key = Key(sessionIDs: sessionIDs, dayStart: Calendar.current.startOfDay(for: day))
        entries[key] = nil
    }

    /// Drop everything. Useful when the camera list changes (add /
    /// remove) since the cache key is parameterized by session IDs.
    public func invalidateAll() {
        entries.removeAll()
    }

    private static func ttl(for dayStart: Date) -> TimeInterval {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if dayStart >= todayStart {
            return 30
        }
        return 60 * 60
    }
}

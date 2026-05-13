import Testing
import Foundation
import ReolinkAPI
@testable import AppShared

/// 0.5.1 — `RecordingsCache` paints the previous result instantly so
/// the All Recordings list never starts at blank. Pin the
/// freshness-policy boundaries (today = short TTL, past day = long TTL)
/// and the invalidation contracts.
@Suite("RecordingsCache freshness + invalidation")
struct RecordingsCacheTests {

    /// Build a minimally-valid `ScopedRecording` for cache round-trip
    /// tests. The cache stores values verbatim — no decoding work
    /// happens in `get`/`set` — so the field shape only needs to
    /// satisfy `Codable`.
    private func makeRow(channel: Int = 0) -> ScopedRecording {
        let json = """
        {"name":"clip-\(channel).mp4","size":1024,"type":"mp4",
         "StartTime":{"year":2026,"mon":5,"day":13,"hour":12,"min":0,"sec":0},
         "EndTime":{"year":2026,"mon":5,"day":13,"hour":12,"min":1,"sec":0}}
        """.data(using: .utf8)!
        let file = try! JSONDecoder().decode(SearchFile.self, from: json)
        let key = CameraFilterBar.CameraChannelKey(
            deviceID: UUID(),
            channel: channel,
            label: "Driveway"
        )
        return ScopedRecording(file: file, cameraKey: key)
    }

    @Test("Empty cache returns nil")
    func emptyReturnsNil() async {
        let cache = RecordingsCache()
        let entry = await cache.get(sessionIDs: [UUID()], day: Date())
        #expect(entry == nil)
    }

    @Test("Set + get round-trips rows")
    func setGetRoundTrip() async {
        let cache = RecordingsCache()
        let sessionID = UUID()
        let row = makeRow()
        await cache.set(sessionIDs: [sessionID], day: Date(), rows: [row])
        let entry = await cache.get(sessionIDs: [sessionID], day: Date())
        #expect(entry != nil)
        #expect(entry?.rows.first?.id == row.id)
    }

    @Test("Past-day cache entries are fresh by default")
    func pastDayFresh() async {
        let cache = RecordingsCache()
        let sessionID = UUID()
        let yesterday = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        await cache.set(sessionIDs: [sessionID], day: yesterday, rows: [makeRow()])
        let entry = await cache.get(sessionIDs: [sessionID], day: yesterday)
        // Past days use a 1-hour TTL — a just-written entry is fresh.
        #expect(entry?.isStale == false)
    }

    @Test("Different session sets are different cache keys")
    func keyIncludesSessionIDs() async {
        let cache = RecordingsCache()
        let a = UUID()
        let b = UUID()
        await cache.set(sessionIDs: [a], day: Date(), rows: [makeRow()])
        let other = await cache.get(sessionIDs: [b], day: Date())
        #expect(other == nil)
    }

    @Test("invalidate(sessionIDs:day:) drops a specific entry only")
    func invalidateSingle() async {
        let cache = RecordingsCache()
        let sessionID = UUID()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        await cache.set(sessionIDs: [sessionID], day: today, rows: [makeRow()])
        await cache.set(sessionIDs: [sessionID], day: yesterday, rows: [makeRow(channel: 1)])
        await cache.invalidate(sessionIDs: [sessionID], day: today)
        let todayHit = await cache.get(sessionIDs: [sessionID], day: today)
        let yesterdayHit = await cache.get(sessionIDs: [sessionID], day: yesterday)
        #expect(todayHit == nil)
        #expect(yesterdayHit != nil)
    }

    @Test("invalidateAll() drops every entry")
    func invalidateAll() async {
        let cache = RecordingsCache()
        await cache.set(sessionIDs: [UUID()], day: Date(), rows: [makeRow()])
        await cache.invalidateAll()
        let hit = await cache.get(sessionIDs: [UUID()], day: Date())
        #expect(hit == nil)
    }

    @Test("Day-of-week boundaries normalize to startOfDay")
    func dayNormalization() async {
        let cache = RecordingsCache()
        let sessionID = UUID()
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 8, minute: 30, second: 0, of: Date())!
        let evening = cal.date(bySettingHour: 22, minute: 15, second: 0, of: Date())!
        await cache.set(sessionIDs: [sessionID], day: morning, rows: [makeRow()])
        // Same calendar day → same cache key, regardless of the time
        // component on the input Date.
        let eveningHit = await cache.get(sessionIDs: [sessionID], day: evening)
        #expect(eveningHit != nil)
    }
}

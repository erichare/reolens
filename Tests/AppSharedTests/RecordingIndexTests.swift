import Testing
import Foundation
@testable import AppShared
import ReolinkAPI
import ReolinkBaichuan

/// 0.6.0 — `RecordingIndex` is the cross-day store that powers
/// Slice 11's NL search. Tests cover:
///
/// - Ingestion is idempotent (re-ingesting same camera+day replaces only
///   that camera's rows; other cameras' rows untouched).
/// - Tag merge from Baichuan extends `detectionTags` on existing rows
///   via filename + time-overlap matching.
/// - Query by tag / date range / camera filter.
/// - Retention purge drops days older than `retentionDays`.
/// - Persistence round-trip preserves rows across instances.
/// - File version mismatch falls back to empty store, not corrupt.
@Suite("RecordingIndex")
struct RecordingIndexTests {

    // MARK: - Test helpers

    private func makeFreshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "recording-index-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "recording-index.v1.json")
    }

    private let cameraA = UUID()
    private let cameraB = UUID()

    private func file(name: String, startOffsetSeconds: TimeInterval, triggerMask: Int = 0) -> SearchFile {
        let start = Self.fixedDay.addingTimeInterval(startOffsetSeconds)
        let end = start.addingTimeInterval(60)
        let json = """
        {
          "name": "\(name)",
          "size": 1000,
          "type": "main",
          "StartTime": \(Self.reolinkTimeJSON(start)),
          "EndTime": \(Self.reolinkTimeJSON(end)),
          "frameRate": 30,
          "width": 1920,
          "height": 1080,
          \(triggerMask != 0 ? "\"trigger\": \(triggerMask)," : "")
          "PlaybackTime": \(Self.reolinkTimeJSON(start))
        }
        """
        return try! JSONDecoder().decode(SearchFile.self, from: Data(json.utf8))
    }

    private func alarmVideo(name: String, offset: TimeInterval, alarmType: String) -> BaichuanAlarmVideoFile {
        let start = Self.fixedDay.addingTimeInterval(offset)
        let end = start.addingTimeInterval(60)
        return BaichuanAlarmVideoFile(
            fileName: name,
            startTime: ReolinkTime(date: start),
            endTime: ReolinkTime(date: end),
            alarmType: alarmType
        )
    }

    private static func reolinkTimeJSON(_ date: Date) -> String {
        let c = Calendar.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return "{\"year\": \(c.year!), \"mon\": \(c.month!), \"day\": \(c.day!), \"hour\": \(c.hour!), \"min\": \(c.minute!), \"sec\": \(c.second!)}"
    }

    /// Anchor day used for synthetic recordings. Stable across test
    /// run; gives every helper a known reference point.
    static let fixedDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(8 * 3600)

    // MARK: - Ingestion

    @Test("Ingesting CGI Search files creates indexed rows")
    func basicIngestion() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f1 = file(name: "f1", startOffsetSeconds: 0, triggerMask: DetectionType.person.bit)
        let f2 = file(name: "f2", startOffsetSeconds: 60, triggerMask: 0)
        await index.ingest([f1, f2], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let rows = await index.query()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.fileName == "f1" && $0.detectionTags == [.person] })
        #expect(rows.contains { $0.fileName == "f2" && $0.detectionTags.isEmpty })
    }

    @Test("Re-ingesting same camera+day replaces only that camera's rows")
    func ingestionIsCameraScoped() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let fA = file(name: "a1", startOffsetSeconds: 0)
        let fB = file(name: "b1", startOffsetSeconds: 30)
        await index.ingest([fA], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)
        await index.ingest([fB], cameraID: cameraB, cameraName: "Back", channel: 0, day: Self.fixedDay)
        #expect(await index.count() == 2)

        // Re-ingest cameraA with a different file list — cameraB's row
        // must survive.
        let fA2 = file(name: "a2", startOffsetSeconds: 120)
        await index.ingest([fA2], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let rows = await index.query()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.fileName == "a2" })
        #expect(rows.contains { $0.fileName == "b1" })
        #expect(!rows.contains { $0.fileName == "a1" })
    }

    @Test("Re-ingest with empty list clears that camera's day entries")
    func ingestionWithEmptyClears() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f = file(name: "f1", startOffsetSeconds: 0)
        await index.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)
        #expect(await index.count() == 1)

        await index.ingest([], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)
        #expect(await index.count() == 0)
    }

    // MARK: - Tag merging

    @Test("Baichuan merge extends detectionTags on existing rows by filename")
    func mergeByFilename() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f = file(name: "f1", startOffsetSeconds: 0, triggerMask: DetectionType.motion.bit)
        await index.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let av = alarmVideo(name: "f1", offset: 0, alarmType: "people, vehicle")
        await index.mergeAlarmVideos([av], cameraID: cameraA, channel: 0, day: Self.fixedDay)

        let rows = await index.query()
        #expect(rows.first?.detectionTags == [.motion, .person, .vehicle])
    }

    @Test("Baichuan merge extends detectionTags via time-range overlap")
    func mergeByTimeOverlap() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f = file(name: "cgi-name", startOffsetSeconds: 0, triggerMask: 0)
        await index.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        // Baichuan file uses a different name but the time range overlaps.
        let av = alarmVideo(name: "baichuan-name", offset: 30, alarmType: "package")
        await index.mergeAlarmVideos([av], cameraID: cameraA, channel: 0, day: Self.fixedDay)

        let rows = await index.query()
        #expect(rows.first?.detectionTags == [.packageDelivery])
    }

    @Test("Merge is idempotent — repeated calls don't grow detectionTags")
    func mergeIsIdempotent() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f = file(name: "f1", startOffsetSeconds: 0)
        await index.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)
        let av = alarmVideo(name: "f1", offset: 0, alarmType: "people")
        await index.mergeAlarmVideos([av], cameraID: cameraA, channel: 0, day: Self.fixedDay)
        await index.mergeAlarmVideos([av], cameraID: cameraA, channel: 0, day: Self.fixedDay)

        let rows = await index.query()
        #expect(rows.first?.detectionTags == [.person])
    }

    // MARK: - Queries

    @Test("Query by tag filters out non-matching rows")
    func queryByTag() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f1 = file(name: "people-clip", startOffsetSeconds: 0, triggerMask: DetectionType.person.bit)
        let f2 = file(name: "vehicle-clip", startOffsetSeconds: 60, triggerMask: DetectionType.vehicle.bit)
        let f3 = file(name: "no-tag-clip", startOffsetSeconds: 120, triggerMask: 0)
        await index.ingest([f1, f2, f3], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let onlyPeople = await index.query(RecordingIndex.Query(tagFilter: [.person]))
        #expect(onlyPeople.map(\.fileName) == ["people-clip"])

        let peopleOrVehicle = await index.query(
            RecordingIndex.Query(tagFilter: [.person, .vehicle])
        )
        #expect(Set(peopleOrVehicle.map(\.fileName)) == ["people-clip", "vehicle-clip"])
    }

    @Test("Query by camera filter restricts results")
    func queryByCamera() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let fA = file(name: "a1", startOffsetSeconds: 0)
        let fB = file(name: "b1", startOffsetSeconds: 0)
        await index.ingest([fA], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)
        await index.ingest([fB], cameraID: cameraB, cameraName: "Back", channel: 0, day: Self.fixedDay)

        let onlyA = await index.query(RecordingIndex.Query(cameraIDs: [cameraA]))
        #expect(onlyA.map(\.fileName) == ["a1"])
    }

    @Test("Query results are newest-first")
    func queryOrdering() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let oldest = file(name: "oldest", startOffsetSeconds: 0)
        let middle = file(name: "middle", startOffsetSeconds: 60)
        let newest = file(name: "newest", startOffsetSeconds: 120)
        await index.ingest(
            [oldest, middle, newest],
            cameraID: cameraA,
            cameraName: "Front",
            channel: 0,
            day: Self.fixedDay
        )

        let rows = await index.query()
        #expect(rows.map(\.fileName) == ["newest", "middle", "oldest"])
    }

    @Test("Query limit caps the result count")
    func queryLimit() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let files = (0..<20).map { i in file(name: "f\(i)", startOffsetSeconds: Double(i) * 60) }
        await index.ingest(files, cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let rows = await index.query(RecordingIndex.Query(limit: 5))
        #expect(rows.count == 5)
    }

    // MARK: - Persistence

    @Test("Persistence round-trip preserves rows across instances")
    func persistenceRoundTrip() async {
        let url = makeFreshURL()
        let writer = RecordingIndex(storeURL: url)
        let f = file(name: "persisted", startOffsetSeconds: 0, triggerMask: DetectionType.person.bit)
        await writer.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        let reader = RecordingIndex(storeURL: url)
        let rows = await reader.query()
        #expect(rows.count == 1)
        #expect(rows.first?.fileName == "persisted")
        #expect(rows.first?.detectionTags == [.person])
    }

    @Test("Future schema version is rejected — store loads empty rather than corrupt")
    func futureSchemaVersion() async throws {
        let url = makeFreshURL()
        // Hand-write a future-version file. The actor must reject it
        // and fall back to an empty store.
        let payload = """
        {"version": 999, "rows": []}
        """
        try Data(payload.utf8).write(to: url)

        let index = RecordingIndex(storeURL: url)
        #expect(await index.count() == 0)
    }

    // MARK: - Retention

    @Test("Days older than retention window are purged on ingest")
    func retentionPurge() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url, retentionDays: 7)

        // Ingest a recording 14 days old — within tolerance for ingest,
        // but purge should drop it once we ingest "today".
        let ancientDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let ancientFile = file(name: "ancient", startOffsetSeconds: 0)
        await index.ingest([ancientFile], cameraID: cameraA, cameraName: "Front", channel: 0, day: ancientDay)

        // Today triggers a purge — the ancient day falls outside the
        // 7-day window.
        let todayFile = file(name: "fresh", startOffsetSeconds: 0)
        await index.ingest([todayFile], cameraID: cameraA, cameraName: "Front", channel: 0, day: Date())

        let rows = await index.query()
        #expect(rows.map(\.fileName) == ["fresh"])
    }

    // MARK: - Bookmark flag

    @Test("setBookmark flips hasBookmark on the matching row")
    func bookmarkToggle() async {
        let url = makeFreshURL()
        let index = RecordingIndex(storeURL: url)
        let f = file(name: "bookmarkable", startOffsetSeconds: 0)
        await index.ingest([f], cameraID: cameraA, cameraName: "Front", channel: 0, day: Self.fixedDay)

        await index.setBookmark(cameraID: cameraA, channel: 0, fileName: "bookmarkable", hasBookmark: true)
        let rows = await index.query()
        #expect(rows.first?.hasBookmark == true)

        await index.setBookmark(cameraID: cameraA, channel: 0, fileName: "bookmarkable", hasBookmark: false)
        let rowsAfter = await index.query()
        #expect(rowsAfter.first?.hasBookmark == false)
    }
}

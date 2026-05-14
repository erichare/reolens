import Testing
import Foundation
@testable import AppShared

/// Tests for `NotificationHistory`. Each test gets a freshly-keyed
/// temporary file URL so there's no shared state between tests.
@Suite("NotificationHistory — append, query, persistence")
struct NotificationHistoryTests {

    private static func makeFreshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "reolens-notification-history-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "notifications.json")
    }

    private static func sampleRecord(
        at date: Date = Date(),
        cameraID: UUID = UUID(),
        tag: String? = "people",
        status: NotificationRecord.DeliveryStatus = .posted
    ) -> NotificationRecord {
        NotificationRecord(
            timestamp: date,
            source: .local,
            cameraID: cameraID,
            channel: 0,
            cameraName: "Front Door",
            detectionTag: tag,
            title: "Person detected",
            body: "Front Door",
            deliveryStatus: status
        )
    }

    @Test("Empty actor returns no snapshot")
    func emptySnapshot() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        let items = await history.snapshot()
        #expect(items.isEmpty)
    }

    @Test("Records are stored newest-first")
    func newestFirst() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        let now = Date()
        await history.record(Self.sampleRecord(at: now.addingTimeInterval(-300)))
        await history.record(Self.sampleRecord(at: now.addingTimeInterval(-60)))
        await history.record(Self.sampleRecord(at: now))
        let items = await history.snapshot()
        #expect(items.count == 3)
        #expect(items[0].timestamp == now)
        #expect(items[2].timestamp == now.addingTimeInterval(-300))
    }

    @Test("Cap trims oldest records on overflow")
    func capTrims() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL(), cap: 3)
        for i in 0..<5 {
            await history.record(Self.sampleRecord(at: Date().addingTimeInterval(Double(i))))
        }
        let items = await history.snapshot()
        #expect(items.count == 3)
    }

    @Test("Query filters by camera")
    func queryByCamera() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        let camA = UUID()
        let camB = UUID()
        await history.record(Self.sampleRecord(cameraID: camA))
        await history.record(Self.sampleRecord(cameraID: camB))
        await history.record(Self.sampleRecord(cameraID: camA))
        let onlyA = await history.query(cameraID: camA)
        #expect(onlyA.count == 2)
        #expect(onlyA.allSatisfy { $0.cameraID == camA })
    }

    @Test("Query filters by tag and status independently")
    func queryByTagAndStatus() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        await history.record(Self.sampleRecord(tag: "people", status: .posted))
        await history.record(Self.sampleRecord(tag: "vehicle", status: .posted))
        await history.record(Self.sampleRecord(tag: "people", status: .throttledCooldown))
        let people = await history.query(detectionTag: "people")
        let muted = await history.query(deliveryStatus: .throttledCooldown)
        #expect(people.count == 2)
        #expect(muted.count == 1)
    }

    @Test("markTapped sets tappedAt on a present record")
    func markTapped() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        let record = Self.sampleRecord()
        await history.record(record)
        let now = Date()
        await history.markTapped(id: record.id, at: now)
        let items = await history.snapshot()
        #expect(items.first?.tappedAt == now)
    }

    @Test("markTapped on a missing id is a no-op")
    func markTappedMissing() async {
        let history = NotificationHistory(storeURL: Self.makeFreshURL())
        await history.record(Self.sampleRecord())
        await history.markTapped(id: UUID(), at: Date())  // not in cache
        let items = await history.snapshot()
        #expect(items.first?.tappedAt == nil)
    }

    @Test("Records persist across actor instances")
    func persistsAcrossInstances() async {
        let url = Self.makeFreshURL()
        let first = NotificationHistory(storeURL: url)
        await first.record(Self.sampleRecord())
        await first.record(Self.sampleRecord())
        let second = NotificationHistory(storeURL: url)
        let items = await second.snapshot()
        #expect(items.count == 2)
    }

    @Test("Clear wipes all records and persists the empty state")
    func clearWipes() async {
        let url = Self.makeFreshURL()
        let first = NotificationHistory(storeURL: url)
        await first.record(Self.sampleRecord())
        await first.record(Self.sampleRecord())
        await first.clear()
        let second = NotificationHistory(storeURL: url)
        #expect(await second.snapshot().isEmpty)
    }

    @Test("Future schema versions don't get partial-decoded")
    func futureVersionStartsFresh() async throws {
        let url = Self.makeFreshURL()
        // Write a file claiming version 999.
        let future = """
        {"version": 999, "records": []}
        """
        try future.data(using: .utf8)!.write(to: url)
        let history = NotificationHistory(storeURL: url)
        let items = await history.snapshot()
        #expect(items.isEmpty)
    }
}

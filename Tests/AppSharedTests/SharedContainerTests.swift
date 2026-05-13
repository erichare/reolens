import Testing
import Foundation
@testable import AppShared

/// SharedContainer is the foundation for WidgetKit + Live Activity reads
/// in 0.5.0. These tests verify the codable round-trip and the layout
/// invariants that the widget extension depends on. They DO NOT exercise
/// the App-Group entitlement path — that requires a signed binary; here
/// we drive the encoder/decoder directly via the public types.
@Suite("SharedContainer codable round-trips")
struct SharedContainerCodableTests {

    @Test("LatestSnapshot round-trips through plist")
    func latestSnapshotRoundTrip() throws {
        let snap = SharedContainer.LatestSnapshot(
            cameraID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            channel: 0,
            cameraName: "Front Door",
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            imageRelativePath: "snapshots/front_ch0.jpg",
            lastMotionAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode([snap])
        let decoded = try PropertyListDecoder().decode([SharedContainer.LatestSnapshot].self, from: data)
        #expect(decoded == [snap])
    }

    @Test("RecentMotionEvent round-trips through plist with optional fields")
    func recentMotionEventRoundTrip() throws {
        let event = SharedContainer.RecentMotionEvent(
            id: UUID(),
            cameraID: UUID(),
            channel: 2,
            cameraName: "Backyard",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            aiTags: ["person", "vehicle"],
            triggerFrameRelativePath: nil
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode([event])
        let decoded = try PropertyListDecoder().decode([SharedContainer.RecentMotionEvent].self, from: data)
        #expect(decoded.first?.cameraName == "Backyard")
        #expect(decoded.first?.aiTags == ["person", "vehicle"])
        #expect(decoded.first?.triggerFrameRelativePath == nil)
    }

    @Test("DailyDigestRecord round-trips through JSON")
    func dailyDigestRoundTrip() throws {
        let digest = SharedContainer.DailyDigestRecord(
            day: Date(timeIntervalSince1970: 1_700_000_000),
            totalEvents: 17,
            perCameraCounts: [
                .init(cameraName: "Front Door", count: 9),
                .init(cameraName: "Backyard", count: 8)
            ],
            perTagCounts: ["person": 12, "vehicle": 5],
            peakHour: 3,
            hourlyBuckets: Array(repeating: 0, count: 24)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(digest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SharedContainer.DailyDigestRecord.self, from: data)
        #expect(decoded == digest)
    }

    @Test("Digest filename uses ISO yyyy-MM-dd")
    func digestFilename() {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 12
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let day = Calendar(identifier: .gregorian).date(from: components)!
        #expect(SharedContainer.digestFilename(for: day) == "2026-05-12.json")
    }
}

/// `ReolensScene` is the WindowGroup scene-identifier for 0.5.0's
/// multi-window layout. `WindowGroup(for: ReolensScene.self)` requires
/// `Hashable + Codable` — round-trips matter for state restoration.
@Suite("ReolensScene Codable")
struct ReolensSceneCodableTests {

    @Test("main case round-trips through JSON")
    func mainRoundTrips() throws {
        let scene = ReolensScene.main
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(ReolensScene.self, from: data)
        #expect(decoded == scene)
    }

    @Test("camera case preserves id + channel")
    func cameraRoundTrips() throws {
        let id = UUID()
        let scene = ReolensScene.camera(id: id, channel: 3)
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(ReolensScene.self, from: data)
        #expect(decoded == scene)
    }

    @Test("digest case preserves day")
    func digestRoundTrips() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let scene = ReolensScene.digest(day: day)
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(ReolensScene.self, from: data)
        #expect(decoded == scene)
    }
}

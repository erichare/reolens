import Testing
import Foundation
@testable import AppShared

@Suite("DigestBuilder")
struct DigestBuilderTests {

    private let cameraA = UUID()
    private let cameraB = UUID()

    /// Use Calendar(.gregorian) with a fixed time zone so tests
    /// don't drift on machines in DST transitions.
    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func event(camera: UUID, name: String, hour: Int, day: Date) -> DigestBuilder.InputEvent {
        let ts = day.addingTimeInterval(TimeInterval(hour * 3600))
        return DigestBuilder.InputEvent(cameraID: camera, cameraName: name, detection: "person", timestamp: ts)
    }

    @Test("Total events counts only the day window")
    func totalEventsInWindow() {
        let cal = calendar()
        let day = cal.date(from: DateComponents(year: 2026, month: 5, day: 12))!
        let yesterday = cal.date(byAdding: .day, value: -1, to: day)!
        let events: [DigestBuilder.InputEvent] = [
            event(camera: cameraA, name: "Front", hour: 2, day: day),
            event(camera: cameraA, name: "Front", hour: 5, day: day),
            event(camera: cameraB, name: "Back", hour: 11, day: yesterday),  // outside the window
        ]
        let digest = DigestBuilder.build(day: day, events: events, calendar: cal)
        #expect(digest.totalEvents == 2)
        #expect(digest.day == day)
    }

    @Test("Per-camera counts are sorted by count desc, then name asc")
    func perCameraSorted() {
        let cal = calendar()
        let day = cal.date(from: DateComponents(year: 2026, month: 5, day: 12))!
        let events: [DigestBuilder.InputEvent] = [
            event(camera: cameraA, name: "Apple", hour: 1, day: day),
            event(camera: cameraB, name: "Banana", hour: 2, day: day),
            event(camera: cameraB, name: "Banana", hour: 3, day: day),
        ]
        let digest = DigestBuilder.build(day: day, events: events, calendar: cal)
        #expect(digest.perCameraCounts.first?.cameraName == "Banana")
        #expect(digest.perCameraCounts.first?.count == 2)
    }

    @Test("Peak hour points at the busiest hour")
    func peakHour() {
        let cal = calendar()
        let day = cal.date(from: DateComponents(year: 2026, month: 5, day: 12))!
        let events: [DigestBuilder.InputEvent] = [
            event(camera: cameraA, name: "X", hour: 3, day: day),
            event(camera: cameraA, name: "X", hour: 3, day: day),
            event(camera: cameraA, name: "X", hour: 11, day: day),
        ]
        let digest = DigestBuilder.build(day: day, events: events, calendar: cal)
        #expect(digest.peakHour == 3)
    }

    @Test("Empty input returns a zero-total digest")
    func emptyInput() {
        let cal = calendar()
        let day = cal.date(from: DateComponents(year: 2026, month: 5, day: 12))!
        let digest = DigestBuilder.build(day: day, events: [], calendar: cal)
        #expect(digest.totalEvents == 0)
        #expect(digest.hourlyBuckets.reduce(0, +) == 0)
        #expect(digest.peakHour == 0)
    }
}

@Suite("OvernightDigestSettings defaults")
struct OvernightDigestSettingsTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.digestSettings.\(UUID().uuidString)")!
    }

    @Test("Defaults are enabled at 07:00 when no override is set")
    func defaultsAreEnabled() {
        let settings = OvernightDigestSettings(defaults: freshDefaults())
        #expect(settings.enabled == true)
        #expect(settings.hourOfDay == 7)
    }

    @Test("Hour clamps to 0..23")
    func hourClamps() {
        let settings = OvernightDigestSettings(defaults: freshDefaults())
        settings.setHourOfDay(99)
        #expect(settings.hourOfDay == 23)
        settings.setHourOfDay(-5)
        #expect(settings.hourOfDay == 0)
    }

    @Test("Setting an explicit hour persists")
    func explicitHourPersists() {
        let defaults = freshDefaults()
        let settings = OvernightDigestSettings(defaults: defaults)
        settings.setHourOfDay(9)
        #expect(settings.hourOfDay == 9)
        // A fresh wrapper around the same defaults sees the same value.
        let again = OvernightDigestSettings(defaults: defaults)
        #expect(again.hourOfDay == 9)
    }
}

import Testing
import Foundation
@testable import AppShared
import ReolinkAPI

/// 0.6.0 Slice 12 — `WeeklySchedule` is the editor's data model and
/// the source of truth for the wire-format `01` schedule string. Tests
/// pin the model's contract:
///
/// - 168-cell invariant (7 days × 24 hours).
/// - Round-trip with `scheduleString` matches.
/// - Malformed wire input is rejected (not silently coerced).
/// - `set` / `toggle` / `fill` mutate the right cells.
/// - `changedIndices` is the minimum diff for the "write only changed
///   slots" path.
@Suite("WeeklySchedule")
struct WeeklyScheduleTests {

    @Test("Default-init produces an all-off schedule")
    func defaultIsAllOff() {
        let s = WeeklySchedule()
        #expect(s.activeHourCount == 0)
        #expect(s.scheduleString == String(repeating: "0", count: 168))
    }

    @Test("Parsing a well-formed 01 string round-trips through scheduleString")
    func roundTrip() {
        // Half-on / half-off pattern — varies enough to catch
        // ordering bugs.
        let raw = String(repeating: "10", count: 84)
        let parsed = WeeklySchedule(scheduleString: raw)
        try? #require(parsed != nil)
        #expect(parsed!.scheduleString == raw)
        #expect(parsed!.activeHourCount == 84)
    }

    @Test("Parsing rejects strings that aren't exactly 168 chars")
    func parsingRejectsBadLength() {
        #expect(WeeklySchedule(scheduleString: "1") == nil)
        #expect(WeeklySchedule(scheduleString: String(repeating: "0", count: 100)) == nil)
        #expect(WeeklySchedule(scheduleString: String(repeating: "1", count: 200)) == nil)
    }

    @Test("Parsing rejects strings with characters other than 0 / 1")
    func parsingRejectsBadChars() {
        let bad = String(repeating: "x", count: 168)
        #expect(WeeklySchedule(scheduleString: bad) == nil)
    }

    @Test("set / toggle / isEnabled all map to (weekday * 24 + hour)")
    func indexingIsRowMajor() {
        var s = WeeklySchedule()
        // Wed 14:00 → index 3 * 24 + 14 = 86.
        let coord = WeeklySchedule.CellCoord(weekday: 3, hour: 14)
        s.set(coord, to: true)
        #expect(s.isEnabled(at: coord))
        // Underlying scheduleString must have '1' at index 86 and '0'
        // everywhere else.
        let chars = Array(s.scheduleString)
        #expect(chars[86] == "1")
        for i in 0..<168 where i != 86 {
            #expect(chars[i] == "0")
        }
        s.toggle(coord)
        #expect(!s.isEnabled(at: coord))
    }

    @Test("fill(true) flips every cell on; fill(false) flips every cell off")
    func fillOperations() {
        var s = WeeklySchedule()
        s.fill(value: true)
        #expect(s.activeHourCount == 168)
        s.fill(value: false)
        #expect(s.activeHourCount == 0)
    }

    @Test("changedIndices returns indices that differ between two schedules")
    func diffMinimal() {
        var a = WeeklySchedule()
        var b = WeeklySchedule()
        b.set(WeeklySchedule.CellCoord(weekday: 0, hour: 1), to: true)
        b.set(WeeklySchedule.CellCoord(weekday: 0, hour: 2), to: true)
        let diff = b.changedIndices(comparedTo: a)
        #expect(Set(diff) == [1, 2])

        // Mutating `a` to match `b` should collapse the diff to empty.
        a = b
        #expect(a.changedIndices(comparedTo: b).isEmpty)
    }

    @Test("ScheduleTable.isWellFormed accepts a 168-char 01 string only")
    func wireValidation() {
        #expect(ScheduleTable(mainStream: String(repeating: "1", count: 168)).isWellFormed)
        #expect(!ScheduleTable(mainStream: "1").isWellFormed)
        #expect(!ScheduleTable(mainStream: String(repeating: "x", count: 168)).isWellFormed)
    }

    @Test("allOff / allOn static helpers produce 168-char strings")
    func staticHelpers() {
        #expect(ScheduleTable.allOff.mainStream.count == 168)
        #expect(ScheduleTable.allOn.mainStream.count == 168)
        #expect(ScheduleTable.allOff.mainStream.allSatisfy { $0 == "0" })
        #expect(ScheduleTable.allOn.mainStream.allSatisfy { $0 == "1" })
    }

    @Test("RecordingScheduleSettings round-trips through JSON encode/decode")
    func wireRoundTrip() throws {
        let original = RecordingScheduleSettings(
            channel: 2,
            scheduleTable: ScheduleTable(mainStream: ScheduleTable.allOn.mainStream)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingScheduleSettings.self, from: data)
        #expect(decoded.channel == 2)
        #expect(decoded.scheduleTable.mainStream == ScheduleTable.allOn.mainStream)
    }

    @Test("RecordingScheduleSettings decodes Reolink's canonical Rec.schedule.table shape")
    func decodesCanonicalReolinkShape() throws {
        // What real Reolink Home Hub / RLN firmware actually returns
        // from `GetRec`. This was the wire shape we were missing in
        // 0.6.0 — the previous decoder expected `scheduleTable.main
        // Stream` instead of `schedule.table`, so every read failed
        // with a `malformedResponse` that surfaced to users as
        // "(ReolinkAPI.ReolinkClientError error 4.)".
        let allOn = ScheduleTable.allOn.mainStream
        let json = """
        {
          "channel": 0,
          "overwrite": 1,
          "preRec": 1,
          "postRec": "0",
          "saveDay": 0,
          "schedule": { "enable": 1, "table": "\(allOn)" }
        }
        """
        let decoded = try JSONDecoder().decode(RecordingScheduleSettings.self, from: Data(json.utf8))
        #expect(decoded.channel == 0)
        #expect(decoded.scheduleTable.mainStream == allOn)
    }

    @Test("RecordingScheduleSettings decodes the legacy scheduleTable.mainStream shape")
    func decodesLegacyShape() throws {
        let allOff = ScheduleTable.allOff.mainStream
        let json = """
        {
          "channel": 1,
          "scheduleTable": { "mainStream": "\(allOff)" }
        }
        """
        let decoded = try JSONDecoder().decode(RecordingScheduleSettings.self, from: Data(json.utf8))
        #expect(decoded.channel == 1)
        #expect(decoded.scheduleTable.mainStream == allOff)
    }

    @Test("RecordingScheduleSettings encode emits the canonical Rec.schedule.table shape")
    func encodesCanonicalShape() throws {
        // Writing in shape 1 keeps SetRec compatible across every
        // firmware we've seen accept the write.
        let settings = RecordingScheduleSettings(
            channel: 0,
            scheduleTable: ScheduleTable.allOn
        )
        let data = try JSONEncoder().encode(settings)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try #require(dict != nil)
        let schedule = dict?["schedule"] as? [String: Any]
        try #require(schedule != nil)
        #expect((schedule?["table"] as? String) == ScheduleTable.allOn.mainStream)
        #expect((schedule?["enable"] as? Int) == 1)
        // Must NOT emit the legacy shape.
        #expect(dict?["scheduleTable"] == nil)
    }

    @Test("RecordingScheduleSettings rejects a response missing both shapes with a clear message")
    func rejectsUnknownShape() {
        let json = """
        { "channel": 0, "overwrite": 1 }
        """
        do {
            _ = try JSONDecoder().decode(RecordingScheduleSettings.self, from: Data(json.utf8))
            Issue.record("Expected decode to throw")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("schedule.table"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got: \(error)")
        }
    }
}

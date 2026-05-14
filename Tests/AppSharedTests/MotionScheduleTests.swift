import Testing
import Foundation
@testable import AppShared
import ReolinkAPI

/// 0.6.0 Slice 12b — `MotionScheduleSettings` carries the same 168-
/// char weekly bitmap as the recording schedule, but adds an optional
/// `perTagOverrides` array. Tests pin the wire shape so a serialization
/// regression doesn't break the camera silently.
@Suite("MotionScheduleSettings")
struct MotionScheduleTests {

    @Test("Round-trips through JSON without per-tag overrides")
    func roundTripWithoutOverrides() throws {
        let original = MotionScheduleSettings(
            channel: 0,
            scheduleTable: ScheduleTable.allOn,
            perTagOverrides: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MotionScheduleSettings.self, from: data)
        #expect(decoded.channel == 0)
        #expect(decoded.scheduleTable.mainStream == ScheduleTable.allOn.mainStream)
        #expect(decoded.perTagOverrides == nil)
    }

    @Test("Round-trips through JSON with two per-tag overrides")
    func roundTripWithOverrides() throws {
        let original = MotionScheduleSettings(
            channel: 1,
            scheduleTable: ScheduleTable.allOn,
            perTagOverrides: [
                TagSchedule(tag: "people", table: ScheduleTable.allOff),
                TagSchedule(tag: "vehicle", table: ScheduleTable.allOn)
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MotionScheduleSettings.self, from: data)
        try #require(decoded.perTagOverrides?.count == 2)
        #expect(decoded.perTagOverrides!.first(where: { $0.tag == "people" })?.table.mainStream == ScheduleTable.allOff.mainStream)
        #expect(decoded.perTagOverrides!.first(where: { $0.tag == "vehicle" })?.table.mainStream == ScheduleTable.allOn.mainStream)
    }

    @Test("MotionScheduleEnvelope decodes a server-shaped response")
    func envelopeDecode() throws {
        let json = """
        {
          "MdAlarm": {
            "channel": 2,
            "scheduleTable": {
              "mainStream": "\(ScheduleTable.allOn.mainStream)"
            }
          }
        }
        """
        let env = try JSONDecoder().decode(MotionScheduleEnvelope.self, from: Data(json.utf8))
        #expect(env.MdAlarm.channel == 2)
        #expect(env.MdAlarm.scheduleTable.mainStream == ScheduleTable.allOn.mainStream)
        #expect(env.MdAlarm.perTagOverrides == nil)
    }

    @Test("SchedulePhase equality reflects associated values")
    func phaseEquality() {
        #expect(SchedulePhase.loading == SchedulePhase.loading)
        #expect(SchedulePhase.ready == SchedulePhase.ready)
        #expect(SchedulePhase.unsupported == SchedulePhase.unsupported)
        #expect(SchedulePhase.error("a") == SchedulePhase.error("a"))
        #expect(SchedulePhase.error("a") != SchedulePhase.error("b"))
    }
}

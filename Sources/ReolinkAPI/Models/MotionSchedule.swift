import Foundation

/// 0.6.0 Slice 12b — Reolink CGI `MdAlarm` (motion-detection alarm)
/// schedule wire types.
///
/// Reolink exposes a per-channel weekly schedule for *when* motion
/// triggers should fire alarms. Same shape as the recording schedule
/// (`Rec`): a 168-character bitmap (7 days × 24 hours, row-major
/// Sun → Sat × 00 → 23). `1` = motion can trigger alarms in that
/// hour; `0` = silent.
///
/// Wire format mirrors `RecordingScheduleSettings` — most firmware
/// puts the bitmap under `MdAlarm.schedule.table`; a minority uses
/// `MdAlarm.scheduleTable.mainStream`. We decode either and write
/// the canonical shape on `SetMdAlarm`.
///
/// Per-zone scheduling is a future extension — Reolink's documented
/// `Alarm` block accepts an optional `area` array but firmware
/// support is inconsistent. The wire format is shaped to be future-
/// extensible: adding `area` later doesn't break the existing field
/// set.
///
/// Older firmware responds with rspCode = -9 (not supported); callers
/// route through `CGIErrorCode.notSupport` and degrade to a read-only
/// display, identical to the recording-schedule fallback path.
public struct MotionScheduleSettings: Codable, Sendable, Hashable {
    public let channel: Int
    /// Hourly bitmap for the week. Same encoding as
    /// `ScheduleTable.mainStream`: 168 chars of `0` / `1`.
    public var scheduleTable: ScheduleTable
    /// Reserved for per-detection-tag overrides — e.g. "in this hour
    /// only fire alarms for people, not motion". When nil (the
    /// common case) the schedule applies to *every* tag the channel
    /// is configured to detect.
    public var perTagOverrides: [TagSchedule]?

    public init(
        channel: Int,
        scheduleTable: ScheduleTable,
        perTagOverrides: [TagSchedule]? = nil
    ) {
        self.channel = channel
        self.scheduleTable = scheduleTable
        self.perTagOverrides = perTagOverrides
    }

    enum CodingKeys: String, CodingKey {
        case channel
        case schedule         // Shape 1 — `MdAlarm.schedule.table`
        case scheduleTable    // Shape 2 — `MdAlarm.scheduleTable.mainStream`
        case perTagOverrides
    }

    // safe: the four `try?` sites below are intentional firmware-shape
    // fallbacks — channel default, shape 1 / shape 2 schedule probes,
    // and the optional perTagOverrides field whose absence is normal
    // on cameras whose firmware doesn't expose AI-tag schedules.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channel = (try? c.decode(Int.self, forKey: .channel)) ?? 0
        if let table = try? c.decode(ScheduleTable.Shape1.self, forKey: .schedule) {
            self.scheduleTable = ScheduleTable(mainStream: table.table)
        } else if let table = try? c.decode(ScheduleTable.self, forKey: .scheduleTable) {
            self.scheduleTable = table
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "MdAlarm response is missing both `schedule.table` and `scheduleTable.mainStream`. Firmware may use an undocumented variant — capture the raw response and report it."
            ))
        }
        self.perTagOverrides = try? c.decodeIfPresent([TagSchedule].self, forKey: .perTagOverrides)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channel, forKey: .channel)
        try c.encode(
            ScheduleTable.Shape1(enable: 1, table: scheduleTable.mainStream),
            forKey: .schedule
        )
        try c.encodeIfPresent(perTagOverrides, forKey: .perTagOverrides)
    }
}

/// Per-tag schedule override. Each carries a tag name (matching the
/// Reolink AI string vocabulary — `"people"`, `"vehicle"`,
/// `"dog_cat"`, etc.) and its own 168-char bitmap that overrides the
/// channel-level schedule for that single tag.
public struct TagSchedule: Codable, Sendable, Hashable {
    public let tag: String
    public var table: ScheduleTable

    public init(tag: String, table: ScheduleTable) {
        self.tag = tag
        self.table = table
    }
}

public struct MotionScheduleEnvelope: Codable, Sendable {
    public let MdAlarm: MotionScheduleSettings
}

public struct SetMotionScheduleParam: Encodable, Sendable {
    public let MdAlarm: MotionScheduleSettings
}

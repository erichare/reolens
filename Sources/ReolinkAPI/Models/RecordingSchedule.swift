import Foundation

/// 0.6.0 Slice 12 — Reolink CGI `Rec` (recording schedule) wire types.
///
/// Reolink exposes a per-channel weekly recording schedule via the
/// `Rec` CGI command family. The schedule is a 7×24 grid (one cell per
/// hour) encoded as a 168-character bitmap string: `1` = record, `0` =
/// don't record, ordered row-major Sun→Sat × 00:00→23:00.
///
/// Wire shape is firmware-dependent. The two encodings we've seen in
/// the wild are:
///
/// 1. **`Rec.schedule.table`** — the most common shape across Reolink
///    Home Hub / RLN-series firmware. `table` is the 168-char bitmap.
///    `schedule.enable` toggles the whole schedule on/off.
/// 2. **`Rec.scheduleTable.mainStream`** — alternate shape on a
///    handful of firmwares where the bitmap is per-stream rather than
///    per-channel.
///
/// We decode both and re-encode in shape (1) on write because that's
/// what every observed firmware accepts. Older firmware that doesn't
/// recognize `GetRec` at all responds with rspCode = -9 (not
/// supported); callers downgrade to a read-only display via the
/// existing `CGIErrorCode.notSupport` fallback.
public struct RecordingScheduleSettings: Codable, Sendable, Hashable {
    public let channel: Int
    public var scheduleTable: ScheduleTable

    public init(channel: Int, scheduleTable: ScheduleTable) {
        self.channel = channel
        self.scheduleTable = scheduleTable
    }

    enum CodingKeys: String, CodingKey {
        case channel
        case schedule       // Shape 1 — `Rec.schedule.table`
        case scheduleTable  // Shape 2 — `Rec.scheduleTable.mainStream`
    }

    // safe: the three `try?` sites below are intentional firmware-shape
    // fallbacks — `channel` defaults to 0 when missing, and the two
    // schedule probes try shape 1 then shape 2 before throwing a
    // precise dataCorrupted error if neither matched.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channel = (try? c.decode(Int.self, forKey: .channel)) ?? 0
        // Try shape 1 first (most common), then fall back to shape 2.
        if let table = try? c.decode(ScheduleTable.Shape1.self, forKey: .schedule) {
            self.scheduleTable = ScheduleTable(mainStream: table.table)
        } else if let table = try? c.decode(ScheduleTable.self, forKey: .scheduleTable) {
            self.scheduleTable = table
        } else {
            // Neither shape decoded — surface a precise error so the
            // user-visible message points at the actual cause.
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "Rec response is missing both `schedule.table` and `scheduleTable.mainStream`. The camera's firmware may use an undocumented variant; capture the raw response and report it."
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // Always write in shape 1 — every firmware that supports
        // `SetRec` accepts it; shape 2 was a misread on our part.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channel, forKey: .channel)
        try c.encode(
            ScheduleTable.Shape1(enable: 1, table: scheduleTable.mainStream),
            forKey: .schedule
        )
    }
}

public struct ScheduleTable: Codable, Sendable, Hashable {
    /// 168-character `01` string. Indexed row-major: weekday 0 = Sunday,
    /// hour 0 = midnight. Index = `weekday * 24 + hour`.
    public var mainStream: String

    public init(mainStream: String) {
        self.mainStream = mainStream
    }

    /// All-zeros / all-recording defaults for the editor's "Clear" /
    /// "Always record" buttons.
    public static let allOff = ScheduleTable(mainStream: String(repeating: "0", count: 168))
    public static let allOn = ScheduleTable(mainStream: String(repeating: "1", count: 168))

    /// True when the schedule string is exactly 168 chars of `0` / `1`.
    /// Used by validators before a `SetRec` call.
    public var isWellFormed: Bool {
        guard mainStream.count == 168 else { return false }
        return mainStream.allSatisfy { $0 == "0" || $0 == "1" }
    }

    /// Internal shape used to decode `Rec.schedule.{enable, table}`.
    /// Public so the outer `RecordingScheduleSettings.init(from:)` can
    /// declare it as a decoded type, but consumers should always work
    /// with `ScheduleTable` directly.
    public struct Shape1: Codable, Sendable, Hashable {
        public let enable: Int
        public let table: String
    }
}

public struct RecordingScheduleEnvelope: Codable, Sendable {
    public let Rec: RecordingScheduleSettings
}

public struct SetRecordingScheduleParam: Encodable, Sendable {
    public let Rec: RecordingScheduleSettings
}

import Foundation
import ReolinkAPI

/// A historical alarm/AI event returned by the hub's `GetEvents` (or similar)
/// command. The exact JSON shape varies by firmware — we don't know it yet —
/// so the decoder is permissive: it tries several plausible field names and
/// returns nil for anything it can't make sense of.
public struct HubEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let startTime: Date?
    public let endTime: Date?
    public let detectionTypes: [DetectionType]

    public func overlaps(start: Date, end: Date) -> Bool {
        guard let evStart = startTime else { return false }
        let evEnd = endTime ?? evStart
        // Inclusive overlap check
        return !(evEnd < start || evStart > end)
    }
}

/// Wrapper for the `GetEvents` response. The actual key names Reolink uses
/// vary; this decoder tries the most common candidates.
public struct HubEventEnvelope: Decodable, Sendable {
    public let events: [HubEvent]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: AnyJSON].self)
        // Try a few plausible top-level keys: `EventList`, `Events`, `events`,
        // `AlarmList`, `Alarm`, …
        let candidates = ["EventList", "Events", "events", "AlarmList", "Alarm", "AiEventList"]
        var found: [AnyJSON] = []
        for key in candidates {
            if let arr = raw[key]?.array { found = arr; break }
        }
        self.events = found.compactMap(HubEvent.init(json:))
    }
}

extension HubEvent {
    init?(json: AnyJSON) {
        guard let dict = json.dictionary else { return nil }
        // Try to extract start/end timestamps under any of several names.
        let startCandidates = ["StartTime", "startTime", "start", "BeginTime"]
        let endCandidates = ["EndTime", "endTime", "end", "FinishTime"]
        var startDate: Date?
        var endDate: Date?
        for key in startCandidates {
            if let v = dict[key], let date = parseDate(v) { startDate = date; break }
        }
        for key in endCandidates {
            if let v = dict[key], let date = parseDate(v) { endDate = date; break }
        }

        // Detection type: try several encodings.
        var detections: [DetectionType] = []
        // 1. Bitfield under `trigger`/`Trigger`/`triggerType`
        for key in ["trigger", "Trigger", "triggerType", "type", "eventType", "alarmType"] {
            if let mask = dict[key]?.int {
                detections.append(contentsOf: DetectionType.allCases.filter { mask & $0.bit != 0 })
                break
            }
        }
        // 2. String list — "type": "people,vehicle" or array
        if detections.isEmpty {
            for key in ["aiType", "aiTypes", "detections", "types"] {
                if let strs = dict[key]?.stringList {
                    detections.append(contentsOf: strs.compactMap(DetectionType.fromReolinkString))
                    break
                }
            }
        }

        let id = dict["id"]?.string
            ?? dict["uid"]?.string
            ?? "\(startDate?.timeIntervalSince1970 ?? 0)"
        self.id = id
        self.startTime = startDate
        self.endTime = endDate
        self.detectionTypes = detections
    }
}

private func parseDate(_ v: AnyJSON) -> Date? {
    // ReolinkTime struct: { year, mon, day, hour, min, sec }
    if let d = v.dictionary, let year = d["year"]?.int, let mon = d["mon"]?.int, let day = d["day"]?.int {
        var c = DateComponents()
        c.year = year; c.month = mon; c.day = day
        c.hour = d["hour"]?.int ?? 0
        c.minute = d["min"]?.int ?? 0
        c.second = d["sec"]?.int ?? 0
        return Calendar.gregorian.date(from: c)
    }
    if let n = v.int { return Date(timeIntervalSince1970: TimeInterval(n)) }
    return nil
}

public extension DetectionType {
    /// Map common Reolink string labels (from `GetAiState`/`aiType`/etc.) to
    /// our enum.
    static func fromReolinkString(_ s: String) -> DetectionType? {
        switch s.lowercased() {
        case "motion", "md": .motion
        case "people", "person", "human": .person
        case "vehicle", "car": .vehicle
        case "dog_cat", "pet", "animal": .pet
        case "face": .face
        case "package": .packageDelivery
        case "visitor", "doorbell": .visitor
        case "other": .other
        default: nil
        }
    }
}

/// A loose JSON wrapper that lets us probe arbitrary keys without committing
/// to a fixed shape.
public enum AnyJSON: Decodable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: AnyJSON].self) { self = .object(o) }
        else { self = .null }
    }

    public var int: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        case .string(let s): Int(s)
        default: nil
        }
    }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [AnyJSON]? { if case .array(let a) = self { a } else { nil } }
    public var dictionary: [String: AnyJSON]? { if case .object(let o) = self { o } else { nil } }
    public var stringList: [String]? {
        if let arr = array { return arr.compactMap(\.string) }
        if let s = string { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }
    public subscript(key: String) -> AnyJSON? { dictionary?[key] }
}

import Foundation

public struct SearchParam: Encodable, Sendable {
    public let Search: SearchBody

    public struct SearchBody: Encodable, Sendable {
        public let channel: Int
        public let onlyStatus: Int
        public let streamType: String
        public let StartTime: ReolinkTime
        public let EndTime: ReolinkTime

        public init(
            channel: Int,
            onlyStatus: Bool,
            streamType: String,
            start: Date,
            end: Date
        ) {
            self.channel = channel
            self.onlyStatus = onlyStatus ? 1 : 0
            self.streamType = streamType
            self.StartTime = ReolinkTime(date: start)
            self.EndTime = ReolinkTime(date: end)
        }
    }

    public init(_ body: SearchBody) {
        self.Search = body
    }
}

public struct SearchEnvelope: Decodable, Sendable {
    public let SearchResult: SearchResult
}

public struct SearchResult: Decodable, Sendable {
    public let channel: Int
    public let Status: [SearchStatus]?
    public let File: [SearchFile]?
}

/// Day-by-day recording status for a month. `table` is a string where each
/// character is `0` (no recording) or `1` (has recording) for day-1..day-31.
public struct SearchStatus: Decodable, Sendable, Hashable {
    public let year: Int
    public let mon: Int
    public let table: String

    /// Returns the days of the month that have recordings (1-indexed).
    public var daysWithRecordings: [Int] {
        zip(table.indices, table).enumerated().compactMap { idx, pair in
            pair.1 == "1" ? idx + 1 : nil
        }
    }
}

public struct SearchFile: Decodable, Sendable, Hashable, Identifiable {
    public let name: String
    public let size: Int?
    public let type: String?
    public let StartTime: ReolinkTime
    public let EndTime: ReolinkTime
    public let frameRate: Int?
    public let width: Int?
    public let height: Int?
    public let PlaybackTime: ReolinkTime?
    /// Bitfield describing what triggered the recording. Reolink firmware
    /// varies — newer hubs populate this for all recordings, older ones don't.
    /// See `triggers` for a decoded enum list.
    public let trigger: Int?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, type, StartTime, EndTime, frameRate, width, height, PlaybackTime
        case trigger, Trigger      // Reolink firmware uses one or the other
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        // Reolink firmware returns `size` as either a JSON number or a string
        // (large files often arrive as strings to dodge 32-bit number limits).
        if let intVal = try? c.decode(Int.self, forKey: .size) {
            self.size = intVal
        } else if let strVal = try? c.decode(String.self, forKey: .size) {
            self.size = Int(strVal)
        } else {
            self.size = nil
        }
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.StartTime = try c.decode(ReolinkTime.self, forKey: .StartTime)
        self.EndTime = try c.decode(ReolinkTime.self, forKey: .EndTime)
        self.frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.PlaybackTime = try c.decodeIfPresent(ReolinkTime.self, forKey: .PlaybackTime)
        // Try both `trigger` (lowercase, older firmware) and `Trigger`
        // (uppercase, newer Home Hub firmware).
        self.trigger = (try? c.decodeIfPresent(Int.self, forKey: .trigger))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .Trigger))
    }

    /// Decoded list of what triggered this recording. May be empty if firmware
    /// didn't populate the trigger field or it was zero.
    public var triggers: [DetectionType] {
        guard let mask = trigger, mask > 0 else { return [] }
        return DetectionType.allCases.filter { mask & $0.bit != 0 }
    }

    public var startDate: Date? { StartTime.date() }
    public var endDate: Date? { EndTime.date() }
    public var durationSeconds: TimeInterval? {
        guard let s = startDate, let e = endDate else { return nil }
        return e.timeIntervalSince(s)
    }
    public var sizeMB: Double? {
        guard let size, size > 0 else { return nil }
        return Double(size) / 1024.0 / 1024.0
    }
}

/// Reolink trigger bitfield values. Order and bits inferred from
/// observed `GetAiState` + `Search` results across firmware versions.
public enum DetectionType: String, Sendable, CaseIterable, Hashable {
    case motion, person, vehicle, pet, face, packageDelivery, visitor, other

    public var bit: Int {
        switch self {
        case .motion: 0x01
        case .person: 0x02
        case .vehicle: 0x04
        case .pet: 0x08
        case .face: 0x10
        case .packageDelivery: 0x20
        case .visitor: 0x40
        case .other: 0x80
        }
    }

    public var label: String {
        switch self {
        case .motion: "Motion"
        case .person: "Person"
        case .vehicle: "Vehicle"
        case .pet: "Pet"
        case .face: "Face"
        case .packageDelivery: "Package"
        case .visitor: "Visitor"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .motion: "figure.walk.motion"
        case .person: "person.fill"
        case .vehicle: "car.fill"
        case .pet: "pawprint.fill"
        case .face: "face.smiling.fill"
        case .packageDelivery: "shippingbox.fill"
        case .visitor: "bell.badge.fill"
        case .other: "sparkles"
        }
    }
}

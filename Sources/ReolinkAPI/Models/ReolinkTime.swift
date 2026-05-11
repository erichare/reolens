import Foundation

/// Reolink encodes dates as a six-field struct (`year`, `mon`, `day`, `hour`,
/// `min`, `sec`) — note the short field names. Used in `Search`, recording
/// `StartTime`/`EndTime`, `GetTime`, etc.
public struct ReolinkTime: Codable, Sendable, Hashable {
    public let year: Int
    public let mon: Int
    public let day: Int
    public let hour: Int
    public let min: Int
    public let sec: Int

    public init(year: Int, mon: Int, day: Int, hour: Int, min: Int, sec: Int) {
        self.year = year
        self.mon = mon
        self.day = day
        self.hour = hour
        self.min = min
        self.sec = sec
    }

    /// Build a ReolinkTime from a Swift `Date` using the Gregorian calendar in
    /// the device's current time zone.
    public init(date: Date, calendar: Calendar = .gregorian) {
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        self.year = comps.year ?? 1970
        self.mon = comps.month ?? 1
        self.day = comps.day ?? 1
        self.hour = comps.hour ?? 0
        self.min = comps.minute ?? 0
        self.sec = comps.second ?? 0
    }

    /// Convert back to a `Date`. Returns nil if components are invalid.
    public func date(in calendar: Calendar = .gregorian) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = mon
        comps.day = day
        comps.hour = hour
        comps.minute = min
        comps.second = sec
        return calendar.date(from: comps)
    }
}

public extension Calendar {
    static let gregorian = Calendar(identifier: .gregorian)
}

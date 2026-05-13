import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "digest")

/// Build a `DailyDigestRecord` from an array of motion events. Pure,
/// stateless, deterministic — easy to unit-test. Production callers
/// scan the previous local-midnight → trigger-time window of
/// `EventNotifier.recentEvents` (or, on macOS, the Baichuan event
/// store) and hand the result to `writeDailyDigest`.
///
/// 0.5.0 Theme A5.
public enum DigestBuilder {

    public struct InputEvent: Sendable, Hashable {
        public let cameraID: UUID
        public let cameraName: String
        public let detection: String
        public let timestamp: Date
        public init(cameraID: UUID, cameraName: String, detection: String, timestamp: Date) {
            self.cameraID = cameraID
            self.cameraName = cameraName
            self.detection = detection
            self.timestamp = timestamp
        }
    }

    public static func build(
        day: Date,
        events: [InputEvent],
        calendar: Calendar = .autoupdatingCurrent
    ) -> SharedContainer.DailyDigestRecord {
        let startOfDay = calendar.startOfDay(for: day)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)

        // Filter to the day's window.
        let inWindow = events.filter { $0.timestamp >= startOfDay && $0.timestamp < endOfDay }

        // Per-camera count.
        var perCamera: [String: Int] = [:]
        var perTag: [String: Int] = [:]
        var buckets = Array(repeating: 0, count: 24)
        for event in inWindow {
            perCamera[event.cameraName, default: 0] += 1
            perTag[event.detection, default: 0] += 1
            let hour = calendar.component(.hour, from: event.timestamp)
            if hour >= 0 && hour < 24 {
                buckets[hour] += 1
            }
        }

        // Peak hour. Ties broken by earliest hour.
        var peak: (hour: Int, count: Int) = (0, -1)
        for (hour, count) in buckets.enumerated() where count > peak.count {
            peak = (hour, count)
        }
        let peakHour = peak.count <= 0 ? 0 : peak.hour

        var perCameraCounts: [SharedContainer.DailyDigestRecord.PerCameraCount] = []
        perCameraCounts.reserveCapacity(perCamera.count)
        for (name, count) in perCamera {
            perCameraCounts.append(.init(cameraName: name, count: count))
        }
        perCameraCounts.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.cameraName < rhs.cameraName
        }

        return SharedContainer.DailyDigestRecord(
            day: startOfDay,
            totalEvents: inWindow.count,
            perCameraCounts: perCameraCounts,
            perTagCounts: perTag,
            peakHour: peakHour,
            hourlyBuckets: buckets
        )
    }
}

/// User-facing settings for the overnight-digest pipeline.
/// Persisted in `UserDefaults` so the daily scheduling task can read
/// them at fire-time, and the iOS Settings screen can write them.
/// Default ON because a once-daily summary is well within the
/// "low-noise" budget; users with shift-work schedules tweak the
/// time.
///
/// `UserDefaults` is injected so tests can use an isolated suite
/// without racing against the shared `.standard` instance.
public struct OvernightDigestSettings {

    public static let enabledKey = "com.reolens.overnightDigest.enabled"
    public static let hourKey = "com.reolens.overnightDigest.hourOfDay"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var enabled: Bool {
        if defaults.object(forKey: Self.enabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.enabledKey)
    }

    public var hourOfDay: Int {
        let raw = defaults.integer(forKey: Self.hourKey)
        if raw == 0 && defaults.object(forKey: Self.hourKey) == nil {
            return 7  // 07:00 local default
        }
        return min(max(raw, 0), 23)
    }

    public func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
    }

    public func setHourOfDay(_ value: Int) {
        defaults.set(min(max(value, 0), 23), forKey: Self.hourKey)
    }

    // MARK: - Backward-compatible static convenience (production paths)

    public static var enabled: Bool { OvernightDigestSettings().enabled }
    public static var hourOfDay: Int { OvernightDigestSettings().hourOfDay }
    public static func setEnabled(_ value: Bool) { OvernightDigestSettings().setEnabled(value) }
    public static func setHourOfDay(_ value: Int) { OvernightDigestSettings().setHourOfDay(value) }
}

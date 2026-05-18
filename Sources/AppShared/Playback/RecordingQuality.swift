import Foundation

/// Quality variant for a Reolink recording. Maps to Reolink's two
/// stored stream qualities:
///   * `.low` — sub stream. Smaller (typically 5–10% the size of main),
///     faster to download, lower resolution. Default for tap-to-play.
///   * `.high` — main stream. Full resolution + bitrate. Default for
///     "Save" / "Export" actions.
///
/// The enum is intentionally Codable + Sendable so it round-trips
/// through UserDefaults via raw values and crosses isolation boundaries
/// inside the playback engine without ceremony.
public enum RecordingQuality: String, Sendable, Codable, CaseIterable, Hashable {
    case low
    case high

    /// Human-readable label for menus and toolbars.
    public var label: String {
        switch self {
        case .low: "Low"
        case .high: "High"
        }
    }

    /// Long-form description used in headers and tooltips.
    public var longLabel: String {
        switch self {
        case .low: "Low quality (sub stream)"
        case .high: "High quality (main stream)"
        }
    }

    /// SF Symbol associated with this quality. The filled variant
    /// represents "more" (high) and matches the existing context-menu
    /// icons used across the recordings UI.
    public var systemImage: String {
        switch self {
        case .low: "play.circle"
        case .high: "play.circle.fill"
        }
    }

    /// The opposite of this quality. Lets callers toggle without
    /// branching: `q = q.flipped`.
    public var flipped: RecordingQuality {
        self == .low ? .high : .low
    }
}

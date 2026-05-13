import Foundation

/// Scene identifier for the multi-window app. 0.5.0 introduces this so
/// each camera can be opened in its own scene under Stage Manager (iPad)
/// and macOS Mission Control. Encoded by `WindowGroup(for: ReolensScene.self)`
/// in [App/ReolensApp.swift] and [AppiOS/Sources/ReolensiOSApp.swift].
///
/// `Codable` is required by `WindowGroup` for state restoration; `Hashable`
/// is required for the scene's identity key.
public enum ReolensScene: Hashable, Codable, Sendable {
    /// Main app window — sidebar + grid + detail.
    case main
    /// Standalone camera window — opened from the sidebar's
    /// "Open in New Window" action.
    case camera(id: UUID, channel: Int)
    /// Standalone digest window — opened by tapping an Overnight Digest
    /// notification. `day` is the day being summarized (local midnight).
    case digest(day: Date)
}

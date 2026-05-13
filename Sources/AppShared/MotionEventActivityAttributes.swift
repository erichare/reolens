import Foundation
// ActivityKit ships its headers on macOS but marks ActivityAttributes
// `unavailable in macOS` — `canImport(ActivityKit)` is true on both
// platforms, so we gate on `os(iOS)` instead. macOS sees an empty
// translation unit (per AGENTS.md §1: documented carve-out for
// iOS-only Live Activities).
#if os(iOS)
import ActivityKit

/// In-flight motion-event Live Activity (0.5.0, iOS 26+).
///
/// One activity per camera at a time: a new fire on the same camera
/// replaces the existing activity rather than stacking. Auto-end at
/// the 4-hour ActivityKit cap. The attributes carry only the
/// rendering data — the activity extension has no network access
/// and reads trigger frames from the App-Group container.
///
/// AGENTS.md §11 (no credentials in payloads), §16 (no network from
/// widget / activity extensions, assets purged at 4 h).
@available(iOS 26.0, *)
public struct MotionEventActivityAttributes: ActivityAttributes, Sendable {

    public typealias ContentState = State

    /// Immutable per-activity metadata.
    public let cameraID: UUID
    public let channel: Int
    public let cameraName: String
    public let startedAt: Date

    public init(cameraID: UUID, channel: Int, cameraName: String, startedAt: Date) {
        self.cameraID = cameraID
        self.channel = channel
        self.cameraName = cameraName
        self.startedAt = startedAt
    }

    /// Mutable state — updated via `Activity.update(...)` as the
    /// motion event accumulates additional AI tags or hits a quiet
    /// period.
    public struct State: Codable, Hashable, Sendable {
        public let aiTags: [String]
        public let lastUpdatedAt: Date
        /// Relative path within the App-Group `activity-assets/`
        /// directory. `nil` while the trigger frame is still being
        /// captured. The extension reads via
        /// `SharedContainer.activityAssetsDirectory`.
        public let triggerFrameRelativePath: String?
        /// Number of new fires coalesced into this activity since
        /// it started; 0 for a single-event activity.
        public let coalescedCount: Int

        public init(
            aiTags: [String],
            lastUpdatedAt: Date,
            triggerFrameRelativePath: String?,
            coalescedCount: Int
        ) {
            self.aiTags = aiTags
            self.lastUpdatedAt = lastUpdatedAt
            self.triggerFrameRelativePath = triggerFrameRelativePath
            self.coalescedCount = coalescedCount
        }
    }
}
#endif

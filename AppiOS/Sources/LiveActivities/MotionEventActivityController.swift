import Foundation
@preconcurrency import ActivityKit
import OSLog
import AppShared

private let log = Logger(subsystem: "com.reolens.iOS", category: "live-activity")

/// In-flight motion-event Live Activity lifecycle: start, update,
/// end. Wired into `EventNotifier` so that each motion fire that
/// also produces a notification also gets a Live Activity (assuming
/// the user granted Live Activity permission).
///
/// Replace-on-new-event semantics: a fresh motion fire on the same
/// camera ends the previous activity and starts a new one rather
/// than stacking. This keeps Dynamic Island readable and avoids the
/// 4-activity-per-app cap during a busy scene.
///
/// AGENTS.md §16: trigger frames live in the App Group activity-
/// assets directory and are purged at the 4 h cap.
@available(iOS 26.0, *)
@MainActor
public final class MotionEventActivityController {

    public static let shared = MotionEventActivityController()

    /// One activity per camera. Keyed by `cameraID`.
    private var activities: [UUID: Activity<MotionEventActivityAttributes>] = [:]

    private init() {}

    /// Start a new activity for this camera, replacing any existing
    /// activity on the same camera. The trigger frame, if any, is
    /// written to the shared App-Group container so the widget
    /// extension can render it without network access.
    public func start(
        cameraID: UUID,
        channel: Int,
        cameraName: String,
        aiTags: [String],
        triggerFrameJPEG: Data?
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("Live Activities disabled by user; skipping")
            return
        }
        // Replace any prior activity for this camera.
        if let prior = activities[cameraID] {
            await prior.end(dismissalPolicy: .immediate)
            activities[cameraID] = nil
        }
        let now = Date()
        let assetID = UUID()
        var triggerRel: String?
        if let triggerFrameJPEG {
            if let url = try? SharedContainer.writeActivityFrame(eventID: assetID, jpegData: triggerFrameJPEG) {
                triggerRel = url.lastPathComponent
            }
        }
        let attributes = MotionEventActivityAttributes(
            cameraID: cameraID,
            channel: channel,
            cameraName: cameraName,
            startedAt: now
        )
        let state = MotionEventActivityAttributes.State(
            aiTags: aiTags,
            lastUpdatedAt: now,
            triggerFrameRelativePath: triggerRel,
            coalescedCount: 0
        )
        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(4 * 60 * 60)
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activities[cameraID] = activity
            log.info("Started Live Activity for camera \(cameraName, privacy: .public)")
        } catch {
            log.warning("Activity.request failed: \(error.localizedDescription, privacy: .public)")
        }
        // Opportunistic stale-asset purge.
        SharedContainer.purgeStaleActivityAssets()
    }

    /// Update the existing activity for this camera. Used when a
    /// second AI tag arrives shortly after the first (e.g. motion
    /// then person), or when the rate-limiter coalesces follow-up
    /// fires.
    public func update(
        cameraID: UUID,
        aiTags: [String],
        coalescedCount: Int
    ) async {
        guard let activity = activities[cameraID] else { return }
        let state = MotionEventActivityAttributes.State(
            aiTags: aiTags,
            lastUpdatedAt: .now,
            triggerFrameRelativePath: activity.content.state.triggerFrameRelativePath,
            coalescedCount: coalescedCount
        )
        let content = ActivityContent(
            state: state,
            staleDate: activity.attributes.startedAt.addingTimeInterval(4 * 60 * 60)
        )
        await activity.update(content)
    }

    /// End the activity for this camera (user dismissed, or
    /// 4 h cap). Activity ends with `.default` dismissal so iOS
    /// shows the final state briefly before fading out.
    public func end(cameraID: UUID) async {
        guard let activity = activities[cameraID] else { return }
        await activity.end(dismissalPolicy: .default)
        activities[cameraID] = nil
    }
}

/// `MotionEventLiveActivityBridge` adapter for the AppShared
/// `EventNotifier` to call into without importing `ActivityKit`. The
/// iOS app registers this at launch (see `ReolensiOSApp.swift`).
@available(iOS 26.0, *)
public struct MotionEventActivityBridge: MotionEventLiveActivityBridge {

    public init() {}

    public func start(
        cameraID: UUID,
        channel: Int,
        cameraName: String,
        aiTags: [String],
        triggerFrameJPEG: Data?
    ) async {
        await MotionEventActivityController.shared.start(
            cameraID: cameraID,
            channel: channel,
            cameraName: cameraName,
            aiTags: aiTags,
            triggerFrameJPEG: triggerFrameJPEG
        )
    }
}

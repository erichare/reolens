import Foundation
@preconcurrency import ActivityKit
import OSLog
import AppShared

private let log = Logger(subsystem: "com.reolens.iOS", category: "live-activity")

/// In-flight motion-event Live Activity lifecycle: start, update,
/// end. Wired into `EventNotifier` so each motion fire that also
/// produces a notification also gets a Live Activity (assuming the
/// user granted Live Activity permission).
///
/// 0.5.1 changes:
/// - **Hub-grouped semantics.** Activities are keyed by hub
///   (`cameraID`); a fresh fire on a different channel under the
///   same hub *merges* into the existing activity instead of ending
///   it and starting fresh. This keeps the Dynamic Island readable
///   on multi-channel NVRs that often emit several events in quick
///   succession.
/// - **8 h stale date** (was 4 h) so a slow-burn evening of events
///   doesn't expire mid-watch.
/// - **Push token registration.** When the user has push enabled,
///   `Activity.request(... pushType: .token)` is used and the
///   issued APNs token is forwarded to
///   `LiveActivityPushTokenRegistry` for a future server-driven
///   sender to consume. The local Baichuan-event-driven update path
///   keeps working — push is purely additive.
/// - **Relevance score** so when multiple hubs have activities, the
///   most-recently-active one is prominent in Dynamic Island.
///
/// AGENTS.md §16: trigger frames live in the App Group activity-
/// assets directory and are purged at the activity cap.
@available(iOS 26.0, *)
@MainActor
public final class MotionEventActivityController {

    public static let shared = MotionEventActivityController()

    /// Activity-stale window. 8 h matches typical user attention
    /// spans for an active sitting (vs. the original 4 h which
    /// expired during slow evenings).
    private static let staleWindow: TimeInterval = 8 * 60 * 60

    /// One activity per hub. Keyed by `cameraID` (the hub UUID).
    private var activities: [UUID: Activity<MotionEventActivityAttributes>] = [:]
    private var pushObservers: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Start (or merge into) an activity for this hub. If an activity
    /// already exists for the hub, the new fire updates it instead of
    /// replacing it.
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
        if let existing = activities[cameraID] {
            await mergeFire(
                into: existing,
                cameraID: cameraID,
                cameraName: cameraName,
                newTags: aiTags
            )
            return
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
            staleDate: now.addingTimeInterval(Self.staleWindow),
            relevanceScore: relevanceScore(for: now)
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            activities[cameraID] = activity
            observePushTokens(for: activity, cameraID: cameraID)
            log.info("Started Live Activity for hub \(cameraName, privacy: .public)")
        } catch {
            log.warning("Activity.request failed: \(error.localizedDescription, privacy: .public)")
        }
        // Opportunistic stale-asset purge.
        SharedContainer.purgeStaleActivityAssets()
    }

    /// Update an existing hub-scoped activity. Used directly when a
    /// second AI tag arrives shortly after the first (e.g. motion
    /// then person) or when the rate-limiter coalesces follow-up
    /// fires.
    public func update(
        cameraID: UUID,
        aiTags: [String],
        coalescedCount: Int
    ) async {
        guard let activity = activities[cameraID] else { return }
        let now = Date()
        let state = MotionEventActivityAttributes.State(
            aiTags: aiTags,
            lastUpdatedAt: now,
            triggerFrameRelativePath: activity.content.state.triggerFrameRelativePath,
            coalescedCount: coalescedCount
        )
        let content = ActivityContent(
            state: state,
            staleDate: activity.attributes.startedAt.addingTimeInterval(Self.staleWindow),
            relevanceScore: relevanceScore(for: now)
        )
        await activity.update(content)
    }

    /// End the activity for this hub (user dismissed, or cap hit).
    /// Activity ends with `.default` dismissal so iOS shows the final
    /// state briefly before fading out.
    public func end(cameraID: UUID) async {
        guard let activity = activities[cameraID] else { return }
        await activity.end(dismissalPolicy: .default)
        activities[cameraID] = nil
        pushObservers[cameraID]?.cancel()
        pushObservers[cameraID] = nil
        await LiveActivityPushTokenRegistry.shared.forget(activityID: activity.id)
    }

    // MARK: - Internal

    /// Merge a follow-up fire (different channel, same hub) into an
    /// already-running activity. Dedupes tags and bumps coalescedCount.
    private func mergeFire(
        into activity: Activity<MotionEventActivityAttributes>,
        cameraID: UUID,
        cameraName: String,
        newTags: [String]
    ) async {
        let merged = Array(Set(activity.content.state.aiTags + newTags))
        let coalesced = activity.content.state.coalescedCount + 1
        await update(cameraID: cameraID, aiTags: merged, coalescedCount: coalesced)
        log.info("Merged fire from \(cameraName, privacy: .public) into hub activity (coalesced=\(coalesced))")
    }

    /// Subscribe to `pushTokenUpdates` for this activity and forward
    /// every new token to `LiveActivityPushTokenRegistry`. A future
    /// server-driven sender consumes the registry to push updates.
    private func observePushTokens(
        for activity: Activity<MotionEventActivityAttributes>,
        cameraID: UUID
    ) {
        pushObservers[cameraID]?.cancel()
        pushObservers[cameraID] = Task { [activityID = activity.id] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                let token = LiveActivityPushTokenRegistry.Token(
                    activityID: activityID,
                    cameraID: cameraID,
                    pushTokenHex: hex,
                    issuedAt: Date()
                )
                await LiveActivityPushTokenRegistry.shared.register(token)
            }
        }
    }

    /// Recency-based relevance score. A newer fire scores higher so
    /// Dynamic Island prefers the currently-active hub when multiple
    /// activities are running. Decays linearly over the stale window.
    private func relevanceScore(for date: Date) -> Double {
        let age = max(0, Date().timeIntervalSince(date))
        let normalized = 1.0 - min(1.0, age / Self.staleWindow)
        return normalized
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

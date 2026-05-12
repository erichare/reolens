import Foundation
import SwiftUI

/// Apple Handoff (Continuity) bridging for Reolens, added in 0.4.0.
///
/// When the user opens a camera on iPhone/iPad, an `NSUserActivity` is
/// published with that camera's UUID. macOS receives it through the
/// system Handoff bar in the Dock; clicking the icon (or pressing the
/// Handoff hotkey) routes the activity to the running Mac app, which
/// re-opens the same camera via the existing `OpenCameraIntent` path
/// (a `AppIntentFocus.request(.liveCamera(...))`). Reverse direction
/// works the same way — start on Mac, hand off to iPhone.
///
/// We deliberately use the same focus pipeline the notification-tap
/// handler and Shortcuts/Siri use, so all three sources of "open this
/// camera" funnel through the same code path. No new permissions and
/// no new network surface — Continuity rides on Apple's local infra.
public enum CameraContinuity {
    /// `NSUserActivity.activityType` used in both apps' Info.plist
    /// `NSUserActivityTypes` arrays. Reverse-DNS form keyed off the
    /// website domain matches Apple's convention.
    public static let cameraDetailActivityType = "io.reolens.camera-detail"

    /// Keys inside `userInfo`. Kept small — no hostnames, no
    /// credentials, no display names (AGENTS.md §11).
    public enum UserInfoKey {
        public static let cameraID = "cameraID"
        public static let channelID = "channelID"
    }

    /// Build a fully populated `NSUserActivity` for advertising.
    public static func makeActivity(cameraID: UUID, channelID: Int? = nil, cameraName: String?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: cameraDetailActivityType)
        activity.title = cameraName ?? "Reolens Camera"
        activity.isEligibleForHandoff = true
        // Public/local indexing lets the camera show up in system
        // Spotlight as a side benefit — search "[camera name]" and
        // tapping the result opens the same camera. Strictly local
        // (no CloudKit indexing). Disabled if the user prefers not
        // to expose camera names to Spotlight by opting their device
        // out of Spotlight indexing in System Settings.
        activity.isEligibleForSearch = true
        var info: [String: any Sendable & Hashable] = [
            UserInfoKey.cameraID: cameraID.uuidString
        ]
        if let channelID {
            info[UserInfoKey.channelID] = channelID
        }
        activity.userInfo = info
        // `requiredUserInfoKeys` makes Handoff actually carry these
        // entries across the wire — without it, large activities can
        // arrive with empty `userInfo` on the receiving device.
        activity.requiredUserInfoKeys = [UserInfoKey.cameraID]
        return activity
    }

    /// Translate an incoming `NSUserActivity` into a focus request.
    /// Returns true if the activity was ours and was routed. The
    /// caller (app delegate / scene `onContinueUserActivity`) uses
    /// this to decide whether to also pull a fresh selection from
    /// `CameraStore.applyPendingIntentFocus()`.
    @discardableResult
    public static func handle(activity: NSUserActivity) -> Bool {
        guard activity.activityType == cameraDetailActivityType else { return false }
        guard let userInfo = activity.userInfo,
              let idString = userInfo[UserInfoKey.cameraID] as? String,
              let cameraID = UUID(uuidString: idString) else { return false }
        AppIntentFocus.request(.liveCamera(deviceID: cameraID))
        return true
    }
}

public extension View {
    /// Advertise a camera detail view for Continuity / Handoff.
    /// Adds the right `userActivity` modifier with the Reolens activity
    /// type populated. Tied to the camera's UUID — switching cameras
    /// inside the same view updates the published activity, so picking
    /// up on the other device lands on the right camera.
    func reolensCameraActivity(cameraID: UUID, cameraName: String?, channelID: Int? = nil) -> some View {
        userActivity(
            CameraContinuity.cameraDetailActivityType,
            isActive: true
        ) { activity in
            activity.title = cameraName ?? "Reolens Camera"
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = true
            var info: [String: any Sendable & Hashable] = [
                CameraContinuity.UserInfoKey.cameraID: cameraID.uuidString
            ]
            if let channelID {
                info[CameraContinuity.UserInfoKey.channelID] = channelID
            }
            activity.userInfo = info
            activity.requiredUserInfoKeys = [CameraContinuity.UserInfoKey.cameraID]
        }
    }
}

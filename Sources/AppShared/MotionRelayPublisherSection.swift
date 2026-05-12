import SwiftUI

/// Settings section gating the macOS-side CloudKit motion relay.
/// Added in 0.4.1. AGENTS.md §5 — opt-in, off by default, no
/// telemetry. Setup is one toggle; CloudKit subscriptions on the
/// user's other Apple devices auto-activate via shared iCloud
/// account.
public struct MotionRelayPublisherSection: View {
    @AppStorage(MotionEventRelaySettings.publisherEnabledKey) private var publisherEnabled: Bool = false

    public init() {}

    public var body: some View {
        let cloudKitAvailable = CloudKitAvailability.canUseCloudKit(
            containerID: "iCloud.com.reolens.Reolens"
        )
        Section("Push notifications to iPhone / iPad") {
            Toggle("Relay motion events to my other Apple devices", isOn: $publisherEnabled)
                .disabled(!cloudKitAvailable)
            if cloudKitAvailable {
                Text("New in 0.4.1. When on, this Mac uses your iCloud account to push motion events to your other Apple devices — so Reolens on iPhone/iPad can post notifications even when the app is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This works without any Reolens server — events ride through Apple's CloudKit under your own iCloud account. Apple throttles silent push delivery for free iCloud tiers, so busy cameras may not get every event. Requires this Mac running with the menu-bar mode on (Settings → General).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Label("iCloud isn't available on this Reolens build.", systemImage: "icloud.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text("Locally-built (./Scripts/build-app.sh) Reolens uses slim entitlements that drop the iCloud container to keep AMFI happy. Install the Developer-ID-signed release DMG to use the CloudKit motion-event relay. The toggle is disabled until iCloud is reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

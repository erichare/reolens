import SwiftUI

/// Settings section gating the macOS-side CloudKit motion relay.
/// Added in 0.4.1. AGENTS.md §5 — opt-in, off by default, no
/// telemetry. Setup is one toggle; CloudKit subscriptions on the
/// user's other Apple devices auto-activate via shared iCloud
/// account.
public struct MotionRelayPublisherSection: View {
    @AppStorage(MotionEventRelaySettings.publisherEnabledKey) private var publisherEnabled: Bool = false
    @State private var sendingTestEvent: Bool = false
    @State private var testEventFeedback: String?

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
                Button {
                    Task { await sendTestEvent() }
                } label: {
                    if sendingTestEvent {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                    } else {
                        Label("Send test event via CloudKit", systemImage: "paperplane")
                    }
                }
                .controlSize(.small)
                .disabled(sendingTestEvent || !publisherEnabled || !cloudKitAvailable)
                if let testEventFeedback {
                    Text(testEventFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    /// Publishes a synthetic `MotionEvent` to CloudKit. The receiving
    /// iOS device fans this out through the same subscriber path as a
    /// real motion event, so it's a true end-to-end test of the relay
    /// pipeline — APNS registration on iOS, the CloudKit subscription,
    /// the publisher's account guard, and the receiver's local-
    /// notification compose path all participate. The detection string
    /// is set to "test" so the receiving device can render a distinct
    /// title.
    private func sendTestEvent() async {
        sendingTestEvent = true
        defer { sendingTestEvent = false }

        // Random cameraID per press so the rate-limiter never blocks a
        // legitimate test (it caps at 30 events / 10 min / camera).
        let event = MotionEvent(
            cameraID: UUID(),
            channel: 0,
            detection: "test",
            timestamp: Date(),
            cameraName: "Relay test"
        )
        let publisher = CloudKitMotionEventPublisher()
        await publisher.publish(event)

        // Read back the outcome from the diagnostics actor so the user
        // sees what happened immediately — much friendlier than
        // pointing them to the diagnostics screen.
        let snapshot = await RelayDiagnostics.shared.snapshot()
        if snapshot.lastPublisherSaveSucceeded == true {
            testEventFeedback = "Test event published. Open Reolens on your iPhone or iPad within ~30 s to confirm the notification arrived."
        } else if let outcome = snapshot.lastPublisherSaveOutcome {
            testEventFeedback = "Publish reported: \(outcome). See the diagnostics row below for context."
        } else {
            testEventFeedback = "Publish attempted; check the diagnostics row below for the recorded outcome."
        }
    }
}

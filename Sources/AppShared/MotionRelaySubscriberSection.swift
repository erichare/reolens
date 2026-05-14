#if os(iOS)
import SwiftUI
import UserNotifications

/// iOS Settings section gating the CloudKit motion-event subscriber.
/// Symmetric to the macOS-side `MotionRelayPublisherSection`. Added
/// in 0.6.0 — until now the toggle (`subscriberEnabled`, default ON)
/// was effectively invisible, leaving users with no surface to
/// confirm or change the relay reception state on iOS.
///
/// AGENTS.md §5 — the subscriber writes nothing externally; it only
/// receives CloudKit silent pushes through the user's own iCloud
/// account.
public struct MotionRelaySubscriberSection: View {
    /// `@AppStorage` requires a non-optional default; the actual default
    /// when the key is missing is read by `MotionEventRelaySettings`
    /// (also defaults to true) — the two are aligned.
    @AppStorage(MotionEventRelaySettings.subscriberEnabledKey)
    private var subscriberEnabled: Bool = true

    @State private var sendingTest: Bool = false
    @State private var testFeedback: String?

    public init() {}

    public var body: some View {
        Section("Receive motion events from other Apple devices") {
            Toggle("Receive on this iPhone / iPad", isOn: $subscriberEnabled)
            Text("Apple's CloudKit silently delivers motion events from your Mac (or another Mac running Reolens with the relay publisher on) to this device. The setting takes effect on next app launch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !subscriberEnabled {
                Label("Subscription paused — motion notifications from other devices will not arrive.", systemImage: "bell.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await postTestLocalNotification() }
            } label: {
                if sendingTest {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sending…")
                    }
                } else {
                    Label("Send test notification on this device", systemImage: "paperplane")
                }
            }
            .disabled(sendingTest)

            if let testFeedback {
                Text(testFeedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Posts a local `UNUserNotificationCenter` notification immediately.
    /// Verifies the post-delivery half of the pipeline (system permission,
    /// notification center, sound + badge) without needing a publisher
    /// device or a real camera event.
    private func postTestLocalNotification() async {
        sendingTest = true
        defer { sendingTest = false }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            testFeedback = "System permission for notifications isn't granted on this device."
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Reolens test notification"
        content.body = "Tap this to confirm push delivery works on this device."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "reolens.diagnostics.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            testFeedback = "Test notification posted. If it doesn't appear in Notification Center, check iOS Settings → Reolens → Notifications."
        } catch {
            testFeedback = "Failed to post test notification: \(error.localizedDescription)"
        }
    }
}
#endif

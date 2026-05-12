import SwiftUI
import UserNotifications
import AppShared

/// iOS Settings tab. Uses a single grouped `Form` (instead of the
/// macOS app's TabView-based settings window) because iOS settings
/// idiom is one long-scroll page per top-level entry point.
///
/// All the configurable state — notification toggles, permission
/// status, developer mode — comes from `AppShared` types
/// (`EventNotifier`, `CameraStore`), so this view is purely
/// presentation. Edits sync to iCloud through the same channels as
/// the macOS app.
struct SettingsView: View {
    @Environment(CameraStore.self) private var store
    @State private var notifier = EventNotifier.shared
    @AppStorage(GridPreviewSetting.liveGridDefaultsKey) private var liveGridEnabled: Bool = false

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notifier.enabled)
                Text("Post a notification with a snapshot whenever the hub reports motion or AI events on one of your cameras.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Event types") {
                Toggle("AI events (person, vehicle, pet, …)", isOn: $notifier.notifyAI)
                Toggle("Motion only (no AI classification)", isOn: $notifier.notifyMotion)
                Text("Motion-only events can flood when sustained — leave off unless you want every triggered second.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!notifier.enabled)

            NotificationCategoriesSection(notifier: notifier)

            Section("System permission") {
                permissionRow
            }

            Section("Cameras") {
                LabeledContent("Configured", value: "\(store.cameras.count)")
                if store.cameras.isEmpty {
                    Text("Add a camera in the Devices tab. The list syncs to your Mac and other iCloud-signed-in devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Grid previews") {
                Toggle("Live previews in grid", isOn: $liveGridEnabled)
                Text("New in 0.4.0. By default, the camera grid shows the last snapshot from each camera and only streams live when you open a single camera — friendlier on battery and cellular. Turn this on to stream every grid tile live (uses more battery and data).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ICloudKeychainSyncSection()

            Section("Developer") {
                Toggle("Developer mode", isOn: bindable.developerMode)
                Text("Surfaces diagnostic UI for debugging. Off by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                // Read from Bundle.main so the version reflects whatever
                // marketing version Xcode shipped — keeps the Settings
                // tab from drifting out of sync with the actual build.
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                Link("Project on GitHub", destination: URL(string: "https://github.com/jestatsio/reolens")!)
                Link("Report an issue", destination: URL(string: "https://github.com/jestatsio/reolens/issues")!)
            }

            Section {
                Text("Reolens is a native client for Reolink cameras and NVRs. Camera list and grid preferences sync via iCloud. Passwords stay on each device's Keychain by default — opt in to iCloud Keychain Sync above to share them across your devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await notifier.refreshPermissionStatus() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch notifier.permissionStatus {
        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Granted").foregroundStyle(.secondary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                    Text("Denied — re-enable in Settings.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Notification Settings") {
                    notifier.openSystemSettings()
                }
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 8) {
                Text("Permission not requested yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Request permission") {
                    Task { await notifier.requestPermission() }
                }
            }
        @unknown default:
            Text(String(describing: notifier.permissionStatus))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// `@Bindable` wrapper for the `@Observable` store, so the toggle
    /// can bind to `store.developerMode` without us needing to thread
    /// the store down through a custom binding.
    private var bindable: Bindable<CameraStore> { Bindable(store) }
}

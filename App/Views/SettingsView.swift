import SwiftUI
import UserNotifications
import AppShared

struct SettingsView: View {
    @Environment(CameraStore.self) private var store
    @State private var notifier = EventNotifier.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            developerTab
                .tabItem { Label("Developer", systemImage: "hammer") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }

    private var generalTab: some View {
        Form {
            LabeledContent("Cameras configured") {
                Text("\(store.cameras.count)")
            }
            Text("Settings UI is a placeholder. Camera-specific options will move here (snapshot interval, polling cadence, preferred stream).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var notificationsTab: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $notifier.enabled)
                Text("Post a macOS notification (with a still from the camera) whenever your hub reports motion or AI events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Event types") {
                Toggle("AI events (person, vehicle, pet, …)", isOn: $notifier.notifyAI)
                Toggle("Motion only (no AI classification)", isOn: $notifier.notifyMotion)
                Text("Motion-only events can flood when sustained — leave off unless you want every triggered second.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!notifier.enabled)
            Section("System permission") {
                permissionRow
            }
        }
        .formStyle(.grouped)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                    Text("Denied — re-enable in System Settings.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Notification Settings") {
                    notifier.openSystemSettings()
                }
                .controlSize(.small)
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 6) {
                Text("Permission not requested yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request permission") {
                    Task { await notifier.requestPermission() }
                }
                .controlSize(.small)
            }
        @unknown default:
            Text(String(describing: notifier.permissionStatus))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var developerTab: some View {
        @Bindable var store = store
        return Form {
            Section {
                Toggle("Developer mode", isOn: $store.developerMode)
                Text("Surfaces diagnostic UI for debugging: Raw JSON popovers in the recordings view and other low-level inspection tools. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Text("Reolens")
                .font(.title2.weight(.semibold))
            Text("A modern, native macOS client for Reolink cameras and NVRs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

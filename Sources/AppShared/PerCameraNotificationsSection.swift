import SwiftUI

/// 0.5.1 — Settings → Notifications section listing every configured
/// camera with a per-camera Notify toggle. Defaults to on. State syncs
/// across the user's Apple devices via
/// `CameraNotificationPreferences` (NSUbiquitousKeyValueStore).
///
/// Shared between the macOS Settings TabView and the iOS Settings form
/// because the layout is identical: one row per camera, a toggle, a
/// short subtitle showing the host.
public struct PerCameraNotificationsSection: View {
    @Environment(CameraStore.self) private var store
    @State private var prefs = CameraNotificationPreferences.shared

    public init() {}

    public var body: some View {
        Section {
            if store.cameras.isEmpty {
                Text("No cameras yet. Add one in the Devices tab; per-camera notification toggles will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.orderedCameras()) { entry in
                    cameraRow(for: entry)
                }
            }
        } header: {
            Text("Per-camera notifications")
        } footer: {
            Text("All cameras notify by default. Turn one off to silence its motion and AI events without affecting the others. Syncs across your Apple devices.")
        }
    }

    @ViewBuilder
    private func cameraRow(for entry: CameraEntry) -> some View {
        Toggle(isOn: Binding(
            get: { prefs.isNotificationsEnabled(for: entry.id) },
            set: { prefs.setNotificationsEnabled($0, for: entry.id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                Text(entry.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

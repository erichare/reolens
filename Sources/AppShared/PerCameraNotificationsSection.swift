import SwiftUI
import ReolinkAPI

/// 0.5.1 — Settings → Notifications section listing every configured
/// camera with a per-camera Notify toggle. Defaults to on. State syncs
/// across the user's Apple devices via
/// `CameraNotificationPreferences` (NSUbiquitousKeyValueStore).
///
/// Shared between the macOS Settings TabView and the iOS Settings form
/// because the layout is identical: one row per camera, a toggle, a
/// short subtitle showing the host.
///
/// 0.6.3 — Multi-channel hubs expand into a `DisclosureGroup` with a
/// row per nested camera. The hub-level toggle still mutes all of its
/// channels at once; the per-channel toggles let the user silence
/// just one camera under a hub. Single-channel devices keep the flat
/// toggle they had before.
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
            Text("All cameras notify by default. Turn one off to silence its motion and AI events without affecting the others. Multi-channel hubs expand to a row per camera so a single nested camera can be silenced. Syncs across your Apple devices.")
        }
    }

    @ViewBuilder
    private func cameraRow(for entry: CameraEntry) -> some View {
        // Use `liveChannels` so a 32-channel DVR with 6 cameras
        // paired only shows the 6 real cameras here — same filter
        // the main camera list uses (`CameraSession.liveChannels`
        // drops slots with no name AND no typeInfo).
        let channels = store.session(for: entry.id)?.liveChannels ?? []
        if channels.count > 1 {
            hubRow(for: entry, channels: channels)
        } else {
            deviceToggleRow(for: entry)
        }
    }

    /// Single-camera device — same flat toggle as before.
    @ViewBuilder
    private func deviceToggleRow(for entry: CameraEntry) -> some View {
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

    /// Multi-channel hub — a disclosure group with the hub-level
    /// toggle on top and one toggle per nested camera. When the hub
    /// is muted, the child rows are disabled (their state is preserved
    /// but the device-level mute supersedes them, so showing them as
    /// "on" would be misleading).
    @ViewBuilder
    private func hubRow(for entry: CameraEntry, channels: [ChannelStatus]) -> some View {
        let deviceEnabled = prefs.isNotificationsEnabled(for: entry.id)
        DisclosureGroup {
            ForEach(channels) { ch in
                Toggle(isOn: Binding(
                    get: { prefs.isNotificationsEnabled(for: entry.id, channel: ch.channel) },
                    set: { prefs.setNotificationsEnabled($0, for: entry.id, channel: ch.channel) }
                )) {
                    Text(channelLabel(for: ch))
                }
                .disabled(!deviceEnabled)
            }
        } label: {
            Toggle(isOn: Binding(
                get: { deviceEnabled },
                set: { prefs.setNotificationsEnabled($0, for: entry.id) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                    Text(hubSubtitle(entry: entry, channels: channels, deviceEnabled: deviceEnabled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func channelLabel(for ch: ChannelStatus) -> String {
        let trimmed = (ch.name ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Camera \(ch.channel + 1)"
        }
        return trimmed
    }

    /// Subtitle that summarizes how many of the hub's channels are
    /// currently silenced, so the user can see the state of the
    /// nested toggles without expanding the disclosure.
    private func hubSubtitle(
        entry: CameraEntry,
        channels: [ChannelStatus],
        deviceEnabled: Bool
    ) -> String {
        if !deviceEnabled { return "Hub silenced — every camera muted" }
        let mutedCount = channels.reduce(into: 0) { acc, ch in
            if !prefs.isNotificationsEnabled(for: entry.id, channel: ch.channel) {
                acc += 1
            }
        }
        if mutedCount == 0 { return entry.host }
        if mutedCount == channels.count { return "All cameras silenced" }
        return "\(mutedCount) of \(channels.count) cameras silenced"
    }
}

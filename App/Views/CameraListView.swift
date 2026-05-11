import SwiftUI
import ReolinkAPI
import ReolinkBaichuan

struct CameraListView: View {
    @Environment(CameraStore.self) private var store
    @Binding var showingAddCamera: Bool

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("Devices") {
                ForEach(store.cameras) { entry in
                    DeviceSidebarRow(entry: entry)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddCamera = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Reolens")
    }
}

/// One row per registered device. Expands to a child list of channels for
/// hubs/NVRs/anything with `>1` channel.
struct DeviceSidebarRow: View {
    @Environment(CameraStore.self) private var store
    let entry: CameraEntry

    var body: some View {
        let session = store.session(for: entry.id)
        // Reolink Home Hub reports all 24 paired-camera slots even when most
        // are empty. Empty slots come back with no name and no typeInfo and
        // would otherwise pollute the sidebar with "Channel N" entries we
        // can't actually do anything with — filter them here.
        let channels = (session?.channels ?? []).filter { ch in
            (ch.name?.isEmpty == false) || (ch.typeInfo?.isEmpty == false)
        }

        if channels.count > 1 {
            DisclosureGroup(isExpanded: bindingForExpansion(deviceID: entry.id)) {
                ForEach(channels) { channel in
                    ChannelSidebarRow(deviceID: entry.id, channel: channel)
                        .tag(SidebarSelection.channel(deviceID: entry.id, channel: channel.channel))
                }
            } label: {
                DeviceRowLabel(entry: entry, session: session, channelCount: channels.count)
                    .tag(SidebarSelection.device(entry.id))
                    .contextMenu { removeButton }
            }
        } else {
            DeviceRowLabel(entry: entry, session: session, channelCount: channels.count)
                .tag(SidebarSelection.device(entry.id))
                .contextMenu { removeButton }
        }
    }

    private var removeButton: some View {
        Button("Remove", role: .destructive) {
            store.remove(entry.id)
        }
    }

    /// Expanded state is per-device, persisted in-memory only.
    private func bindingForExpansion(deviceID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.expandedDevices.contains(deviceID) },
            set: { isOpen in
                if isOpen { store.expandedDevices.insert(deviceID) }
                else { store.expandedDevices.remove(deviceID) }
            }
        )
    }
}

struct DeviceRowLabel: View {
    let entry: CameraEntry
    let session: CameraSession?
    let channelCount: Int

    private var deviceIcon: String {
        if let info = session?.deviceInfo {
            if info.isHomeHub { return "house.fill" }
            if info.isNVR { return "rectangle.stack.fill" }
        }
        return "video.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusDot(for: session?.status ?? .disconnected)
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        if channelCount > 1 {
            return "\(entry.host) · \(channelCount) channels"
        }
        return entry.host
    }

    @ViewBuilder
    private func statusDot(for status: ConnectionStatus) -> some View {
        let color: Color = switch status {
        case .connected: .green
        case .connecting: .yellow
        case .error: .red
        case .disconnected: .gray
        }
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct ChannelSidebarRow: View {
    @Environment(CameraStore.self) private var store
    let deviceID: UUID
    let channel: ChannelStatus

    var body: some View {
        let session = store.sessions[deviceID]
        let triggered = session?.aiTriggered[channel.channel] == true
            || session?.motionState[channel.channel] == true
        let battery = session?.batteryByChannel[channel.channel]
        HStack(spacing: 6) {
            Image(systemName: channel.isAsleep ? "moon.zzz" : "video.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(channel.name ?? "Channel \(channel.channel + 1)")
                .lineLimit(1)
            Spacer()
            if triggered {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 6))
            }
            if let battery {
                BatteryBadge(info: battery)
            }
            if !channel.isOnline {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
            }
        }
    }
}

/// Tiny battery glyph for paired battery cameras. The fill level uses
/// SF Symbols' built-in `battery.0/25/50/75/100` variants; tint switches
/// to red below 20 % and green while charging. Exact percentage is in the
/// hover tooltip — `.help(...)` wires that up natively on macOS.
struct BatteryBadge: View {
    let info: BaichuanBatteryInfo

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(tint)
            .font(.caption2)
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }

    private var symbolName: String {
        if info.isCharging { return "battery.100.bolt" }
        switch info.percent {
        case 0..<13:  return "battery.0"
        case 13..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default:      return "battery.100"
        }
    }

    private var tint: Color {
        if info.isCharging { return .green }
        if info.isCritical { return .red }
        if info.isLow { return .orange }
        return .secondary
    }

    private var tooltip: String {
        var parts = ["\(info.percent)%"]
        if info.isCharging { parts.append("charging") }
        else if info.isPluggedIn { parts.append("plugged in") }
        if let t = info.temperatureC { parts.append("\(t)°C") }
        return parts.joined(separator: " · ")
    }
}

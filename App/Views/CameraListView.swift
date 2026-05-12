import SwiftUI
import ReolinkAPI
import ReolinkBaichuan
import AppShared

struct CameraListView: View {
    @Environment(CameraStore.self) private var store
    @Binding var showingAddCamera: Bool
    @State private var passwordEntryEntry: CameraEntry?
    @State private var isReordering: Bool = false
    @State private var draggingDevice: UUID?
    @State private var searchText: String = ""

    private var displayedCameras: [CameraEntry] {
        store.orderedCameras(matching: searchText)
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("Devices") {
                ForEach(displayedCameras) { entry in
                    DeviceSidebarRow(entry: entry, passwordEntryEntry: $passwordEntryEntry)
                        .opacity(draggingDevice == entry.id ? 0.35 : 1.0)
                        .jiggle(isActive: isReordering)
                        .onLongPressGesture(minimumDuration: 0.7) {
                            if !isReordering {
                                withAnimation(.easeIn(duration: 0.2)) { isReordering = true }
                            }
                        }
                        .draggable(DeviceDragPayload(deviceID: entry.id)) {
                            HStack(spacing: 6) {
                                Image(systemName: "video.fill")
                                    .foregroundStyle(.white)
                                Text(entry.displayName)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
                            .onAppear { draggingDevice = entry.id }
                            .onDisappear { draggingDevice = nil }
                        }
                        .dropDestination(for: DeviceDragPayload.self) { payload, _ in
                            guard let source = payload.first, source.deviceID != entry.id else { return false }
                            return store.reorderCamera(source: source.deviceID, before: entry.id)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isReordering {
                    Button("Done") {
                        withAnimation(.easeOut(duration: 0.2)) { isReordering = false }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Menu {
                        Button {
                            withAnimation(.easeIn(duration: 0.2)) { isReordering = true }
                        } label: {
                            Label("Rearrange Devices", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        }
                        .disabled(store.cameras.count < 2)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    Button {
                        showingAddCamera = true
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Reolens")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search cameras")
        .sheet(item: $passwordEntryEntry) { entry in
            EnterPasswordSheet(entry: entry)
        }
    }
}

/// One row per registered device. Expands to a child list of channels for
/// hubs/NVRs/anything with `>1` channel.
struct DeviceSidebarRow: View {
    @Environment(CameraStore.self) private var store
    let entry: CameraEntry
    @Binding var passwordEntryEntry: CameraEntry?

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
                    .contextMenu { contextMenuContent(hasSession: session != nil) }
            }
        } else {
            DeviceRowLabel(entry: entry, session: session, channelCount: channels.count)
                .tag(SidebarSelection.device(entry.id))
                .contextMenu { contextMenuContent(hasSession: session != nil) }
        }
    }

    @ViewBuilder
    private func contextMenuContent(hasSession: Bool) -> some View {
        Button(hasSession ? "Update Password…" : "Enter Password…", systemImage: "key.fill") {
            passwordEntryEntry = entry
        }
        if hasSession {
            Button("Reconnect", systemImage: "arrow.clockwise.circle") {
                store.reconnect(entry.id)
            }
        }
        Divider()
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
        // Make the sidebar row a drag source carrying the same
        // `ChannelDragPayload` the grid tiles use. Dropping it onto any
        // grid tile reorders the persisted `channelOrder` via the
        // existing `reorder(deviceID:source:before:allChannels:)` helper,
        // so the dragged camera lands at the target slot. Works for any
        // layout (Adaptive / Spotlight / fixed) without per-layout glue.
        .draggable(ChannelDragPayload(channel: channel.channel)) {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.white)
                Text(channel.name ?? "Channel \(channel.channel + 1)")
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
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

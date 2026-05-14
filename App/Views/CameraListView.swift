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
                    // 0.5.1 — drag / drop / long-press modifiers used
                    // to wrap the whole `DeviceSidebarRow`, but with
                    // hubs auto-expanded by default those modifiers
                    // also covered the child channel rows inside the
                    // DisclosureGroup, intercepting clicks before
                    // `List(selection:)` could process them. They now
                    // live INSIDE `DeviceSidebarRow`, scoped to the
                    // device label only — channel children stay
                    // cleanly tappable. The reorder-mode helpers (jiggle
                    // + opacity-while-dragging) still wrap the row
                    // because they don't touch hit-testing.
                    DeviceSidebarRow(
                        entry: entry,
                        passwordEntryEntry: $passwordEntryEntry,
                        isReordering: $isReordering,
                        draggingDevice: $draggingDevice
                    )
                    .opacity(draggingDevice == entry.id ? 0.35 : 1.0)
                    .jiggle(isActive: isReordering)
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
    @Binding var isReordering: Bool
    @Binding var draggingDevice: UUID?

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
                        // 0.5.1 — extend the hit-test region to the full
                        // row so clicking anywhere in the channel row
                        // (text, status dot, trailing whitespace)
                        // selects the channel. `List(selection:)`
                        // honors `.contentShape(.rect)` for selection
                        // hit-testing on macOS sidebars.
                        .contentShape(.rect)
                        .tag(SidebarSelection.channel(deviceID: entry.id, channel: channel.channel))
                }
            } label: {
                deviceLabel(session: session, channelCount: channels.count)
            }
        } else {
            deviceLabel(session: session, channelCount: channels.count)
        }
    }

    /// 0.5.1 — Drag-and-drop is gated on `isReordering` so the
    /// modifier doesn't intercept ordinary clicks. Sequence of fixes:
    /// 1. Drag/drop used to wrap the whole `DeviceSidebarRow` (which
    ///    includes the DisclosureGroup children); moved inside so it
    ///    only covered the hub label.
    /// 2. Even then, `.draggable` on the device label was eating
    ///    clicks (interpreted as drag-starts) for users who clicked
    ///    with even slight mouse movement — the user-reported "Home
    ///    Hub click is difficult". Now the modifier only applies in
    ///    reorder mode, entered explicitly from the toolbar's
    ///    "Rearrange Devices" menu item. `.dropDestination` stays
    ///    always-on because it's inert outside an active drag, so
    ///    a hub can still accept a dragged sibling regardless of
    ///    whether *this* row is also a drag source.
    /// The 0.7 s long-press shortcut into reorder mode is gone —
    /// it was redundant with the toolbar menu and added gesture
    /// latency to every click on the device label.
    @ViewBuilder
    private func deviceLabel(session: CameraSession?, channelCount: Int) -> some View {
        let label = DeviceRowLabel(entry: entry, session: session, channelCount: channelCount)
            .contentShape(.rect)
            .tag(SidebarSelection.device(entry.id))
            .contextMenu { contextMenuContent(hasSession: session != nil) }
            .dropDestination(for: DeviceDragPayload.self) { payload, _ in
                guard let source = payload.first, source.deviceID != entry.id else { return false }
                return store.reorderCamera(source: source.deviceID, before: entry.id)
            }
        if isReordering {
            label.draggable(DeviceDragPayload(deviceID: entry.id)) {
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
        } else {
            label
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
            // 0.5.0 — multi-window: open this camera in its own
            // window. SwiftUI's `openWindow(value:)` matches the
            // value type against the secondary `WindowGroup(for:
            // ReolensScene.self)` declared in ReolensApp. Pinned to
            // channel 0 because the device-row context-menu doesn't
            // know which specific channel the user wanted — the
            // per-channel row's own menu (added below) handles
            // multi-channel hubs precisely.
            OpenInNewWindowButton(scene: .camera(id: entry.id, channel: 0))
        }
        Divider()
        Button("Remove", role: .destructive) {
            store.remove(entry.id)
        }
    }

    /// Per-device expand/collapse state. 0.5.1 — hubs auto-expand on
    /// first sight; collapse state syncs across the user's devices via
    /// `HubExpansionStore` (NSUbiquitousKeyValueStore-backed).
    private func bindingForExpansion(deviceID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.hubExpansion.isExpanded(deviceID: deviceID) },
            set: { store.hubExpansion.setExpanded($0, for: deviceID) }
        )
    }
}

struct DeviceRowLabel: View {
    let entry: CameraEntry
    let session: CameraSession?
    let channelCount: Int
    @State private var health = CameraNotificationHealth.shared

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
            if let badge = health.badgeText(for: entry.id) {
                Text(badge)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: Capsule())
                    .accessibilityLabel("Last notification \(badge)")
            }
            statusDot(for: session?.status ?? .disconnected)
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        // 0.5.0 Theme E: prefer the structured connection-stage label
        // over the generic "host · N channels" copy while a session
        // is mid-connect, so the user sees "Logging in (retry 2)…"
        // or "Retrying in 3 s" instead of an unexplained yellow dot.
        if let session, session.connectionStage.isWorking {
            return session.connectionStage.shortLabel
        }
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
        // 0.5.0 — per-channel "Open in New Window" routes through
        // the same secondary scene as the device-row context menu,
        // but with the exact channel selected.
        .contextMenu {
            OpenInNewWindowButton(scene: .camera(id: deviceID, channel: channel.channel))
        }
        // 0.5.1: `.draggable` was previously on this row so users
        // could drag a sidebar channel onto a grid tile to reorder
        // the grid. Removed because — combined with macOS auto-
        // expanded hubs — it flakily intercepted clicks as the
        // start of a drag, leaving some channels unselectable on
        // routine taps. Drag-to-reorder still works from the grid
        // tiles themselves (`ChannelDragPayload` is emitted by
        // `LiveCameraTile`); the sidebar shortcut is a niche
        // power-user affordance not worth breaking selection over.
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

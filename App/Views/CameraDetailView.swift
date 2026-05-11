import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import UniformTypeIdentifiers

struct CameraDetailView: View {
    let session: CameraSession
    let focusedChannel: Int?

    @State private var didStart = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .task(id: session.entry.id) {
            guard !didStart else { return }
            didStart = true
            await session.connect()
        }
        .navigationTitle(titleLine)
        .navigationSubtitle(session.deviceInfo?.model ?? session.entry.host)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let focusedChannel,
           let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
            SingleChannelView(session: session, channel: channel)
        } else if session.channels.count > 1 {
            MultiChannelGridView(session: session)
        } else if let channel = session.channels.first {
            SingleChannelView(session: session, channel: channel)
        } else {
            ContentUnavailableView("Connecting…", systemImage: "bolt.horizontal")
        }
    }

    private var titleLine: String {
        if let focusedChannel,
           let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
            return "\(session.entry.displayName) — \(channel.name ?? "Channel \(focusedChannel + 1)")"
        }
        return session.entry.displayName
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let info = session.deviceInfo {
                Label(info.model ?? "Unknown", systemImage: "video.fill")
                if let fw = info.firmVer {
                    Text(fw).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(session.entry.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .error(msg) = session.status {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Compact connection-status pill for the toolbar. The toolbar renders
    /// `Label` with both icon and text full-size, which looks heavy next to
    /// the title; switching to a tinted capsule with a small dot keeps the
    /// information density without the visual weight.
    @ViewBuilder
    private var statusBadge: some View {
        switch session.status {
        case .connected:
            statusPill(text: "Connected", color: .green)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            statusPill(text: "Disconnected", color: .red)
                .help(msg)
        case .disconnected:
            Button {
                Task { await session.connect() }
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .controlSize(.small)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: .capsule)
    }
}

struct SingleChannelView: View {
    let session: CameraSession
    let channel: ChannelStatus

    var body: some View {
        VStack(spacing: 0) {
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PTZControlBar(session: session, channel: channel.channel)
                .padding(8)
        }
    }
}

struct MultiChannelGridView: View {
    let session: CameraSession
    @Environment(CameraStore.self) private var store
    @State private var richViewerChannel: ChannelStatus?
    /// Channel ID currently being dragged. Drives the dim-while-dragging
    /// effect on the source tile and unblocks the drop target so dropping
    /// a tile on itself is a no-op.
    @State private var draggingChannel: Int?

    private var visibleChannels: [ChannelStatus] {
        // Filter out channels with no paired camera. Reolink Home Hub reports
        // 24 slots even when fewer are populated — empty slots have no name and
        // no typeInfo. Keep sleeping/named ones; drop totally-empty rows.
        let live = session.channels.filter { ch in
            (ch.name?.isEmpty == false) || (ch.typeInfo?.isEmpty == false)
        }
        return store.orderedChannels(for: session.entry.id, channels: live)
    }

    var body: some View {
        // When the rich viewer is open, pause ALL grid tiles. Reolink Home Hub
        // has a small per-device concurrent-session cap; running 20+ sub-stream
        // sessions while a main-stream session is also open exhausts it and
        // the hub starts dropping streams after a few seconds.
        let richViewerOpen = richViewerChannel != nil
        let preset = store.gridPreset(for: session.entry.id)
        VStack(spacing: 0) {
            gridControlBar
            Divider()
            grid(preset: preset, richViewerOpen: richViewerOpen)
        }
        .sheet(item: $richViewerChannel) { channel in
            RichViewerSheet(session: session, channel: channel)
        }
    }

    /// Preset picker + helpful hint about drag-to-rearrange. Lives above the
    /// grid so the chrome is visible regardless of scroll position.
    private var gridControlBar: some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: gridPresetBinding) {
                ForEach(GridPreset.allCases) { p in
                    Label(p.label, systemImage: p.systemImage).tag(p)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 130, maxWidth: 170)
            .help("Choose how many cameras to fit in the grid")
            Text("Drag a tile onto another to rearrange.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(visibleChannels.count) camera\(visibleChannels.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var gridPresetBinding: Binding<GridPreset> {
        Binding(
            get: { store.gridPreset(for: session.entry.id) },
            set: { store.setGridPreset($0, for: session.entry.id) }
        )
    }

    /// The actual grid. Adaptive preset uses SwiftUI's adaptive `GridItem`
    /// like before; fixed presets use a `GeometryReader` to compute tile
    /// dimensions so the requested NxN tiles exactly fill the visible
    /// area.
    @ViewBuilder
    private func grid(preset: GridPreset, richViewerOpen: Bool) -> some View {
        if preset == .adaptive {
            adaptiveGrid(richViewerOpen: richViewerOpen)
        } else {
            fixedGrid(preset: preset, richViewerOpen: richViewerOpen)
        }
    }

    private func adaptiveGrid(richViewerOpen: Bool) -> some View {
        let columns = [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 8)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(visibleChannels) { channel in
                    let isDual = session.isDualLens(channel: channel.channel)
                    tile(for: channel, richViewerOpen: richViewerOpen)
                        .frame(minHeight: isDual ? 110 : 160,
                               idealHeight: isDual ? 140 : 210,
                               maxHeight: isDual ? 220 : 320)
                }
            }
            .padding(8)
        }
    }

    /// Fixed N-column / N-row grid sized to fill the visible area. Falls
    /// back to a scrolling layout when there are more cameras than fit on
    /// one page (so a 4×4 view with 24 cameras shows the first 16 and the
    /// rest are scrollable below).
    private func fixedGrid(preset: GridPreset, richViewerOpen: Bool) -> some View {
        let cols = preset.columns ?? 1
        let rows = preset.rowsOnScreen ?? 1
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: cols
        )
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let totalHSpacing = spacing * CGFloat(cols + 1)
            let totalVSpacing = spacing * CGFloat(rows + 1)
            let tileWidth = (geo.size.width - totalHSpacing) / CGFloat(cols)
            let tileHeight = (geo.size.height - totalVSpacing) / CGFloat(rows)
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleChannels) { channel in
                        tile(for: channel, richViewerOpen: richViewerOpen)
                            .frame(width: tileWidth, height: tileHeight)
                    }
                }
                .padding(spacing)
            }
        }
    }

    /// Single source of tile rendering — applies the drag source / drop
    /// target modifiers so any layout (adaptive or fixed) gets the same
    /// reordering behavior.
    @ViewBuilder
    private func tile(for channel: ChannelStatus, richViewerOpen: Bool) -> some View {
        LiveCameraTile(
            session: session,
            channel: channel,
            stream: .sub,
            onTap: { richViewerChannel = channel },
            paused: richViewerOpen
        )
        .opacity(draggingChannel == channel.channel ? 0.35 : 1.0)
        .draggable(ChannelDragPayload(channel: channel.channel)) {
            DragPreview(channel: channel)
                .onAppear { draggingChannel = channel.channel }
                .onDisappear { draggingChannel = nil }
        }
        .dropDestination(for: ChannelDragPayload.self) { payload, _ in
            guard let source = payload.first, source.channel != channel.channel else { return false }
            store.reorder(
                deviceID: session.entry.id,
                source: source.channel,
                before: channel.channel,
                allChannels: visibleChannels
            )
            return true
        }
    }
}

/// `Transferable` payload that flows through SwiftUI's drag-and-drop. We
/// only need the integer channel ID — the rest is recoverable from the
/// session by looking the channel up by that ID.
private struct ChannelDragPayload: Codable, Transferable {
    let channel: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reolensChannelDrag)
    }
}

private extension UTType {
    /// Custom UTI registered just for our drag payloads — avoids the
    /// possibility of accidental drag-and-drop interop with other apps
    /// that publish plain `Int`s.
    static let reolensChannelDrag = UTType(exportedAs: "com.reolens.channelDrag")
}

/// Visual representation of the tile while the user is dragging. SwiftUI
/// renders it under the cursor / finger. Keeping it lightweight (no
/// streaming) prevents the player from re-initializing during a drag.
private struct DragPreview: View {
    let channel: ChannelStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .foregroundStyle(.white)
            Text(channel.name ?? "Channel \(channel.channel + 1)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 8))
        .frame(minWidth: 160)
    }
}

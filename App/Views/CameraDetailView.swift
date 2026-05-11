import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import UniformTypeIdentifiers

struct CameraDetailView: View {
    let session: CameraSession
    let focusedChannel: Int?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @State private var didStart = false

    /// True when the user has collapsed the sidebar via the fullscreen
    /// toggle. We don't navigate into a separate "fullscreen" view —
    /// instead, hiding the sidebar via the `NavigationSplitView` binding
    /// expands the detail pane to fill the window, which is what users
    /// actually want from "fullscreen for camera feeds" inside the app.
    /// (Native macOS fullscreen via the green window button works on top
    /// of this and is the right tool for a kiosk-style display.)
    private var isSidebarHidden: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .task(id: session.entry.id) {
            guard !didStart else { return }
            didStart = true
            await session.connect()
        }
        .navigationTitle(titleLine)
        .navigationSubtitle(session.deviceInfo?.model ?? session.entry.host)
    }

    @ViewBuilder
    private var content: some View {
        if let focusedChannel,
           let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
            // Sidebar selecting a channel now opens the SAME detailed view
            // that clicking a grid tile opens — Live / Recordings / Settings
            // tabs + PTZ + rotate + talkback + fullscreen toggle. Single
            // source of UX so users don't need to remember which entry
            // points expose which controls.
            ChannelDetailContent(
                session: session,
                channel: channel,
                columnVisibility: $columnVisibility
            )
        } else if session.channels.count > 1 {
            MultiChannelGridView(session: session, columnVisibility: $columnVisibility)
        } else if let channel = session.channels.first {
            ChannelDetailContent(
                session: session,
                channel: channel,
                columnVisibility: $columnVisibility
            )
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
}

struct MultiChannelGridView: View {
    let session: CameraSession
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Environment(CameraStore.self) private var store
    @State private var richViewerChannel: ChannelStatus?
    /// Channel ID currently being dragged. Drives the dim-while-dragging
    /// effect on the source tile and unblocks the drop target so dropping
    /// a tile on itself is a no-op.
    @State private var draggingChannel: Int?

    private var visibleChannels: [ChannelStatus] {
        store.orderedChannels(for: session.entry.id, channels: session.liveChannels)
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
            // Spotlight has a "primary camera" concept (the big top-left
            // tile). Surface a picker so users can choose it directly
            // instead of having to drag the right thumbnail into place.
            if store.gridPreset(for: session.entry.id) == .spotlight {
                primaryPicker
            }
            Text("Drag a tile onto another to rearrange.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(visibleChannels.count) camera\(visibleChannels.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                toggleSidebar()
            } label: {
                Label(
                    columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar",
                    systemImage: columnVisibility == .detailOnly
                        ? "sidebar.left"
                        : "rectangle.expand.vertical"
                )
            }
            .help(columnVisibility == .detailOnly
                  ? "Show the camera list"
                  : "Hide the camera list and fill the window with the grid")
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

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .automatic : .detailOnly
        }
    }

    /// The actual grid. Adaptive preset uses SwiftUI's adaptive `GridItem`
    /// like before; fixed presets use a `GeometryReader` to compute tile
    /// dimensions so the requested NxN tiles exactly fill the visible
    /// area.
    @ViewBuilder
    private func grid(preset: GridPreset, richViewerOpen: Bool) -> some View {
        switch preset {
        case .adaptive:
            adaptiveGrid(richViewerOpen: richViewerOpen)
        case .spotlight:
            spotlightGrid(richViewerOpen: richViewerOpen)
        default:
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

    /// Picker that surfaces the current spotlight primary and lets the
    /// user reassign it from any live channel. Hidden when the device
    /// has only one camera (nothing to pick).
    @ViewBuilder
    private var primaryPicker: some View {
        let live = visibleChannels
        if live.count > 1 {
            let primary = live.first { $0.channel == store.primaryChannel(for: session.entry.id) } ?? live.first
            Menu {
                ForEach(live) { ch in
                    Button {
                        store.setPrimary(
                            deviceID: session.entry.id,
                            channel: ch.channel,
                            allChannels: live
                        )
                    } label: {
                        if ch.channel == primary?.channel {
                            Label(ch.name ?? "Channel \(ch.channel + 1)", systemImage: "checkmark")
                        } else {
                            Text(ch.name ?? "Channel \(ch.channel + 1)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text("Primary:")
                        .foregroundStyle(.secondary)
                    Text(primary?.name ?? "—")
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Choose which camera goes in the big spotlight tile")
        }
    }

    /// Spotlight layout: primary tile fills 75% × 75% of the top-left.
    /// Below it sit TWO "sub-spotlight" tiles side-by-side (the bottom
    /// strip is split in half, regardless of how many cameras the device
    /// has — when there's only one sub-spotlight to fill the bottom
    /// strip we let it take the full bottom width; when there are none
    /// we collapse the strip). The right column holds the remaining
    /// thumbnails in a vertical stack. Channel order in
    /// `CameraStore.channelOrder` drives slot assignment:
    ///   [0] primary, [1, 2] sub-spotlights, [3+] right-column thumbnails.
    /// Drag-to-rearrange and the "Make primary" action both promote
    /// channels into these slots without any layout-specific code.
    private func spotlightGrid(richViewerOpen: Bool) -> some View {
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let primaryFraction: CGFloat = 0.75
            let primaryWidth = max(0, (geo.size.width - 2 * spacing) * primaryFraction)
            let primaryHeight = max(0, (geo.size.height - 2 * spacing) * primaryFraction)
            let rightStripWidth = max(0, geo.size.width - primaryWidth - 2 * spacing)
            let bottomStripHeight = max(0, geo.size.height - primaryHeight - 2 * spacing)

            let channels = visibleChannels
            if let primary = channels.first {
                // Slot assignment from the channel order:
                //   [0]    → primary
                //   [1, 2] → sub-spotlights (bottom strip, side by side)
                //   [3+]   → right-column thumbnails
                let subSpotlights = Array(channels.dropFirst().prefix(2))
                let rightThumbs = Array(channels.dropFirst(1 + subSpotlights.count))

                let subWidth = subSpotlights.isEmpty
                    ? 0
                    : (primaryWidth - CGFloat(max(0, subSpotlights.count - 1)) * spacing) / CGFloat(max(1, subSpotlights.count))
                let rightTileHeight = rightThumbs.isEmpty
                    ? 0
                    : (geo.size.height - CGFloat(rightThumbs.count + 1) * spacing) / CGFloat(rightThumbs.count)

                VStack(spacing: spacing) {
                    HStack(alignment: .top, spacing: spacing) {
                        tile(for: primary, richViewerOpen: richViewerOpen)
                            .frame(width: primaryWidth, height: primaryHeight)
                        if rightThumbs.isEmpty {
                            // No right-column thumbnails — collapse the strip
                            // so the primary expands as far as the math
                            // allowed (still 75% by construction, but we
                            // don't want a phantom 25% gap on the right).
                            EmptyView()
                        } else {
                            VStack(spacing: spacing) {
                                ForEach(rightThumbs) { ch in
                                    tile(for: ch, richViewerOpen: richViewerOpen)
                                        .frame(width: rightStripWidth, height: rightTileHeight)
                                }
                            }
                            .frame(width: rightStripWidth, height: geo.size.height - 2 * spacing)
                        }
                    }
                    if !subSpotlights.isEmpty {
                        HStack(spacing: spacing) {
                            ForEach(subSpotlights) { ch in
                                tile(for: ch, richViewerOpen: richViewerOpen)
                                    .frame(width: subWidth, height: bottomStripHeight)
                            }
                        }
                        .frame(width: primaryWidth, height: bottomStripHeight, alignment: .leading)
                    }
                }
                .padding(spacing)
            } else {
                Color.clear
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

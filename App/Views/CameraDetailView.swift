import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import UniformTypeIdentifiers
import AppShared

struct CameraDetailView: View {
    let session: CameraSession
    let focusedChannel: Int?

    @State private var didStart = false

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
            ChannelDetailContent(session: session, channel: channel)
        } else if session.channels.count > 1 {
            MultiChannelGridView(session: session)
        } else if let channel = session.channels.first {
            ChannelDetailContent(session: session, channel: channel)
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
    @Environment(CameraStore.self) private var store
    @State private var richViewerChannel: ChannelStatus?
    /// Channel ID currently being dragged. Drives the dim-while-dragging
    /// effect on the source tile and unblocks the drop target so dropping
    /// a tile on itself is a no-op.
    @State private var draggingChannel: Int?
    /// Reorder mode (iOS-home-screen jiggle). Long-press on any tile (or
    /// the "Edit Layout" button) enters this mode; tiles jiggle and the
    /// tap action that normally opens the rich viewer is suppressed so
    /// the user can drag without accidentally launching the full-screen
    /// player. Escape or the Done button exits.
    @State private var isReordering: Bool = false

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
            if isReordering {
                Text("Drag tiles to rearrange. Press Done or Escape when finished.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Long-press a tile to rearrange.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isReordering {
                Button("Done") {
                    withAnimation(.easeOut(duration: 0.2)) { isReordering = false }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    withAnimation(.easeIn(duration: 0.2)) { isReordering = true }
                } label: {
                    Label("Edit Layout", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .help("Enter rearrange mode (or long-press any tile). ⌘E.")
                .keyboardShortcut("e", modifiers: .command)
            }
            Text("\(visibleChannels.count) camera\(visibleChannels.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Show-sidebar / hide-sidebar lived here before; that was a
            // duplicate of the native toggle `NavigationSplitView` puts
            // in the toolbar via `SidebarCommands()`. Drop it — users
            // get a single canonical sidebar control.
            Button {
                FullscreenViewer.shared.presentGrid(session: session, store: store)
            } label: {
                Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Show the whole grid in a fullscreen window — press Esc to exit")
            .keyboardShortcut("f", modifiers: [.command, .control])
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
        switch preset {
        case .adaptive:
            adaptiveGrid(richViewerOpen: richViewerOpen)
        case .spotlight:
            spotlightGrid(richViewerOpen: richViewerOpen)
        default:
            fixedGrid(preset: preset, richViewerOpen: richViewerOpen)
        }
    }

    /// Adaptive grid — fits as many tiles as the window width allows,
    /// expanding each tile to fill the leftover space. Tile heights are
    /// computed from the resolved tile width to keep a 16:9 aspect
    /// (Reolink default) so widening the window makes tiles larger
    /// instead of leaving rivers of dead space along the edges. Dual-lens
    /// cameras use a wider 8:3 aspect so their stitched frames don't get
    /// center-cropped by `.resizeAspectFill`.
    private func adaptiveGrid(richViewerOpen: Bool) -> some View {
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let padding: CGFloat = 8
            // 280 px is the smallest a tile gets before the camera name
            // and motion / AI badges start crowding the corner. Above
            // that width, each tile shares the leftover horizontal space
            // equally with its siblings.
            let minTileWidth: CGFloat = 280
            let availableWidth = max(minTileWidth, geo.size.width - 2 * padding)
            let columnCount = max(
                1,
                Int((availableWidth + spacing) / (minTileWidth + spacing))
            )
            let tileWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
            let standardTileHeight = tileWidth * 9 / 16
            let dualTileHeight = tileWidth * 3 / 8

            let columns = Array(
                repeating: GridItem(.fixed(tileWidth), spacing: spacing),
                count: columnCount
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleChannels) { channel in
                        let isDual = session.isDualLens(channel: channel.channel)
                        tile(for: channel, richViewerOpen: richViewerOpen)
                            .frame(
                                width: tileWidth,
                                height: isDual ? dualTileHeight : standardTileHeight
                            )
                    }
                }
                .padding(padding)
            }
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
    /// Spotlight layout — surfaces eight cameras around one big primary:
    ///
    ///   ┌────────────────────────┬───────┐
    ///   │                        │ [1]   │
    ///   │                        ├───────┤
    ///   │       PRIMARY [0]      │ [2]   │
    ///   │                        ├───────┤
    ///   │                        │ [3]   │
    ///   │                        ├───────┤
    ///   │                        │ [4]   │
    ///   ├────────────┬───────────┴───────┤
    ///   │   [5]      │   [6]    │  [7]   │
    ///   └────────────┴──────────┴────────┘
    ///
    /// Slot assignment from the persisted `channelOrder`:
    ///   [0]      → primary, top-left (main stream — sharp at full size)
    ///   [1..4]   → 4 thumbnails in the right column (top 75% of height)
    ///   [5..7]   → 3 LARGER tiles spanning the full window width along
    ///              the bottom 25%
    ///   [8+]     → not rendered (the user can drag-reorder or use
    ///              "Make primary" to bring any camera into view)
    ///
    /// When fewer than 8 cameras exist, the missing slots are simply
    /// skipped and adjacent slots take their space:
    ///   - No right thumbnails → primary stretches to the full window
    ///     width (the bottom strip still spans the same full width).
    ///   - No bottom tiles → the top section expands to the full height.
    private func spotlightGrid(richViewerOpen: Bool) -> some View {
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let W = geo.size.width
            let H = geo.size.height
            // 75 / 25 vertical split for the top section vs. bottom strip,
            // with one spacing gap between them eating from the H budget.
            let topRowH = max(0, (H - spacing) * 0.75)
            let bottomH = max(0, (H - spacing) * 0.25)
            // 75 / 25 horizontal split for the primary vs. right column.
            let primaryW = max(0, (W - spacing) * 0.75)
            let rightColW = max(0, (W - spacing) * 0.25)

            let channels = visibleChannels
            if let primary = channels.first {
                let rightTiles = Array(channels.dropFirst(1).prefix(4))
                let bottomTiles = Array(channels.dropFirst(1 + rightTiles.count).prefix(3))

                // Each tile height in the right column accounts for the
                // gaps BETWEEN them (count - 1 spacings).
                let rightTileH = rightTiles.isEmpty
                    ? 0
                    : (topRowH - CGFloat(max(0, rightTiles.count - 1)) * spacing) / CGFloat(max(1, rightTiles.count))
                // Bottom strip spans the FULL window width — three tiles
                // divide (W - 2 spacings).
                let bottomTileW = bottomTiles.isEmpty
                    ? 0
                    : (W - CGFloat(max(0, bottomTiles.count - 1)) * spacing) / CGFloat(max(1, bottomTiles.count))

                // Let the primary absorb empty space when adjacent slots
                // collapse, so we never leave dead pixels in the layout.
                let effPrimaryW = rightTiles.isEmpty ? W : primaryW
                let effTopH = bottomTiles.isEmpty ? H : topRowH

                VStack(spacing: spacing) {
                    HStack(alignment: .top, spacing: spacing) {
                        // Primary uses MAIN stream — sub quality looks
                        // pixelated when blown up to 75% of the window.
                        // The other tiles stay on sub because Reolink
                        // hubs only allow one concurrent main-stream
                        // session at a time on most paired channels.
                        tile(for: primary, stream: .main, richViewerOpen: richViewerOpen)
                            .frame(width: effPrimaryW, height: effTopH)
                        if !rightTiles.isEmpty {
                            VStack(spacing: spacing) {
                                ForEach(rightTiles) { ch in
                                    tile(for: ch, stream: .sub, richViewerOpen: richViewerOpen)
                                        .frame(width: rightColW, height: rightTileH)
                                }
                            }
                            .frame(width: rightColW, height: effTopH)
                        }
                    }
                    if !bottomTiles.isEmpty {
                        HStack(spacing: spacing) {
                            ForEach(bottomTiles) { ch in
                                tile(for: ch, stream: .sub, richViewerOpen: richViewerOpen)
                                    .frame(width: bottomTileW, height: bottomH)
                            }
                        }
                        .frame(width: W, height: bottomH)
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    /// Single source of tile rendering — applies the drag source / drop
    /// target modifiers so any layout (adaptive or fixed) gets the same
    /// reordering behavior. `stream` defaults to `.sub` because the
    /// adaptive / fixed grids all render small tiles where sub is fine;
    /// the spotlight overrides to `.main` for the primary so it doesn't
    /// look pixelated blown up to 75% of the window.
    @ViewBuilder
    private func tile(for channel: ChannelStatus, stream: StreamKind = .sub, richViewerOpen: Bool) -> some View {
        LiveCameraTile(
            session: session,
            channel: channel,
            stream: stream,
            onTap: {
                // Tapping in reorder mode would launch the full-screen
                // viewer and yank the user out of the rearrange flow.
                // Suppress and rely on Escape / Done to exit reorder.
                if !isReordering {
                    richViewerChannel = channel
                }
            },
            paused: richViewerOpen
        )
        // Force a fresh view (and therefore a fresh `LiveCameraTile`
        // @State + `LiveVideoPlayer`) whenever a slot's channel changes.
        // Without this, SwiftUI sees the tile at position N as the same
        // view across renders and reuses the cached player — so changing
        // the spotlight primary via the dropdown would leave the
        // top-left tile showing the OLD camera's stream.
        .id(channel.channel)
        .opacity(draggingChannel == channel.channel ? 0.35 : 1.0)
        .jiggle(isActive: isReordering)
        // 0.7s long-press enters reorder mode. Sits before .draggable so
        // the gesture fires on the press itself rather than waiting for
        // the drag to start — the user sees the jiggle the moment they
        // hold a tile, exactly like the iOS home screen.
        .onLongPressGesture(minimumDuration: 0.7) {
            if !isReordering {
                withAnimation(.easeIn(duration: 0.2)) { isReordering = true }
            }
        }
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

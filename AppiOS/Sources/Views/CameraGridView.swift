import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Multi-channel grid for NVR/Hub cameras on iOS/iPadOS, with all the
/// same layout presets the macOS app exposes: Adaptive, Spotlight, and
/// fixed N×N (2×2 / 3×3 / 4×4 / 5×5 + Single). The preset is persisted
/// per device via `CameraStore.gridPreset(for:)` and syncs across the
/// user's Apple devices through `cameras.json`.
///
/// Tapping a tile opens the per-channel detail. Long-press (0.7s) enters
/// reorder mode (tiles jiggle, drag rearranges), which is suppressed
/// while reorder is active so users don't accidentally launch the player
/// while moving things around.
struct CameraGridView: View {
    let session: CameraSession
    @Environment(CameraStore.self) private var store
    @State private var selectedChannel: ChannelStatus?
    @State private var isReordering: Bool = false
    @State private var draggingChannel: Int?
    /// User's preference for the grid: live RTSP per tile (0.3.0
    /// behavior, now opt-in) vs. cached still previews (0.4.0 default).
    /// `@AppStorage` so flipping the toggle in Settings updates this
    /// view without explicit propagation.
    @AppStorage(GridPreviewSetting.liveGridDefaultsKey) private var liveGridEnabled: Bool = false

    private var visibleChannels: [ChannelStatus] {
        store.orderedChannels(for: session.entry.id, channels: session.liveChannels)
    }

    var body: some View {
        let preset = store.gridPreset(for: session.entry.id)
        Group {
            switch preset {
            case .adaptive:
                adaptiveGrid
            case .spotlight:
                spotlightGrid
            default:
                fixedGrid(preset: preset)
            }
        }
        .refreshable {
            await refreshAllPreviews()
        }
        .background(Color(.systemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            if isReordering {
                withAnimation(.easeOut(duration: 0.2)) { isReordering = false }
            }
        }
        // Present the single-channel detail via fullScreenCover rather
        // than navigationDestination. On iPad inside the three-column
        // NavigationSplitView, value-based programmatic navigation
        // ambiguously routes between the content column and the detail
        // column — SwiftUI ends up re-evaluating the entire split-view
        // hierarchy on every render, which on a 16-channel hub appears
        // as a hard freeze (the main thread spins through Objective-C
        // dispatch and Swift generic-context lookups for every nested
        // view). fullScreenCover sidesteps all of that with a normal
        // modal presentation that's deterministic on every platform.
        .fullScreenCover(item: $selectedChannel) { channel in
            NavigationStack {
                SingleChannelView(session: session, channel: channel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedChannel = nil }
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isReordering {
                    Button("Done") {
                        withAnimation(.easeOut(duration: 0.2)) { isReordering = false }
                    }
                    .accessibilityLabel("Done rearranging")
                } else {
                    // Inline live / still toggle. Bound to the same
                    // @AppStorage flag the Settings pane uses, so
                    // flipping here updates Settings too. Surfaced
                    // above the grid because hunting in Settings for a
                    // default-behavior choice felt like a regression.
                    Button {
                        liveGridEnabled.toggle()
                    } label: {
                        Image(systemName: liveGridEnabled
                              ? "dot.radiowaves.left.and.right"
                              : "photo.stack")
                            .symbolVariant(liveGridEnabled ? .fill : .none)
                    }
                    .accessibilityLabel(liveGridEnabled
                        ? "Switch to still previews"
                        : "Switch to live grid")
                    .accessibilityHint(liveGridEnabled
                        ? "Currently streaming every camera live in the grid"
                        : "Currently showing still previews; tap to stream live")

                    layoutMenu(currentPreset: preset)
                }
            }
        }
    }

    // MARK: - Layout menu

    @ViewBuilder
    private func layoutMenu(currentPreset: GridPreset) -> some View {
        Menu {
            Section("Layout") {
                ForEach(GridPreset.allCases) { p in
                    Button {
                        store.setGridPreset(p, for: session.entry.id)
                    } label: {
                        Label(p.label, systemImage: p.systemImage)
                        if p == currentPreset {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if currentPreset == .spotlight {
                Section("Primary Camera") {
                    let live = visibleChannels
                    let primary = live.first { $0.channel == store.primaryChannel(for: session.entry.id) } ?? live.first
                    ForEach(live, id: \.channel) { ch in
                        Button {
                            store.setPrimary(
                                deviceID: session.entry.id,
                                channel: ch.channel,
                                allChannels: live
                            )
                        } label: {
                            Text(ch.name ?? "Channel \(ch.channel + 1)")
                            if ch.channel == primary?.channel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    withAnimation(.easeIn(duration: 0.2)) { isReordering = true }
                } label: {
                    Label("Rearrange", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .disabled(visibleChannels.count < 2)
            }
        } label: {
            Label(currentPreset.label, systemImage: currentPreset.systemImage)
        }
        .accessibilityLabel("Layout and options")
    }

    // MARK: - Adaptive grid

    private var adaptiveGrid: some View {
        // Tile *width* is uniform per column. Tile *height* follows
        // the camera's native aspect — single-lens cells are 16:9,
        // dual-lens cells are 32:9 (shorter). LazyVGrid sizes each
        // row to the tallest item, so dual cells leave a margin but
        // never letterbox a 32:9 stitched frame into a 16:9 cell —
        // which users perceived as the dual-lens cameras being "too
        // long" with huge black bars.
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let padding: CGFloat = 12
            let minTileWidth: CGFloat = 280
            let availableWidth = max(0, geo.size.width - 2 * padding)
            let columnCount = max(
                1,
                Int((availableWidth + spacing) / (minTileWidth + spacing))
            )
            let tileWidth = max(
                0,
                (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
            )
            let standardTileHeight = tileWidth * 9 / 16
            let dualTileHeight = tileWidth * 9 / 32
            let columns = Array(
                repeating: GridItem(.fixed(tileWidth), spacing: spacing, alignment: .top),
                count: columnCount
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleChannels, id: \.channel) { channel in
                        let isDual = channel.isDualLens
                            || store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
                        tile(for: channel, stream: .sub)
                            .frame(width: tileWidth, height: isDual ? dualTileHeight : standardTileHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(padding)
            }
        }
    }

    // MARK: - Fixed N×N grid

    private func fixedGrid(preset: GridPreset) -> some View {
        let cols = preset.columns ?? 1
        let rows = preset.rowsOnScreen ?? 1
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let totalHSpacing = spacing * CGFloat(cols + 1)
            let totalVSpacing = spacing * CGFloat(rows + 1)
            // Uniform 16:9 cell that fits within both the width and
            // height budget. Cells may end up narrower than a perfect
            // grid would, but they're guaranteed not to overlap.
            let widthFromWidth = max(0, (geo.size.width - totalHSpacing) / CGFloat(cols))
            let widthFromHeight = max(0, (geo.size.height - totalVSpacing) / CGFloat(rows)) * 16 / 9
            let tileWidth = min(widthFromWidth, widthFromHeight)
            let tileHeight = tileWidth * 9 / 16
            let columns = Array(
                repeating: GridItem(.fixed(tileWidth), spacing: spacing, alignment: .top),
                count: cols
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleChannels, id: \.channel) { channel in
                        // Center-crop dual-lens snapshots so a 32:9
                        // stitched frame fills the 16:9 cell instead
                        // of letterboxing into a thin strip. Matches
                        // what live mode already does
                        // (.resizeAspectFill on the display layer).
                        let isDual = channel.isDualLens
                            || store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
                        tile(for: channel, stream: .sub, centerCrop: isDual)
                            .frame(width: tileWidth, height: tileHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(spacing)
            }
        }
    }

    // MARK: - Spotlight grid (mirrors macOS)

    private var spotlightGrid: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let W = geo.size.width
            let H = geo.size.height
            let topRowH = max(0, (H - spacing) * 0.75)
            let bottomH = max(0, (H - spacing) * 0.25)
            let primaryW = max(0, (W - spacing) * 0.75)
            let rightColW = max(0, (W - spacing) * 0.25)

            let channels = visibleChannels
            if let primary = channels.first {
                let rightTiles = Array(channels.dropFirst(1).prefix(4))
                let bottomTiles = Array(channels.dropFirst(1 + rightTiles.count).prefix(3))

                let rightTileH = rightTiles.isEmpty
                    ? 0
                    : (topRowH - CGFloat(max(0, rightTiles.count - 1)) * spacing) / CGFloat(max(1, rightTiles.count))
                let bottomTileW = bottomTiles.isEmpty
                    ? 0
                    : (W - CGFloat(max(0, bottomTiles.count - 1)) * spacing) / CGFloat(max(1, bottomTiles.count))

                let effPrimaryW = rightTiles.isEmpty ? W : primaryW
                let effTopH = bottomTiles.isEmpty ? H : topRowH

                VStack(spacing: spacing) {
                    HStack(alignment: .top, spacing: spacing) {
                        // Primary uses MAIN stream so the big tile isn't pixelated.
                        tile(for: primary, stream: .main)
                            .frame(width: effPrimaryW, height: effTopH)
                        if !rightTiles.isEmpty {
                            VStack(spacing: spacing) {
                                ForEach(rightTiles, id: \.channel) { ch in
                                    tile(for: ch, stream: .sub)
                                        .frame(width: rightColW, height: rightTileH)
                                }
                            }
                            .frame(width: rightColW, height: effTopH)
                        }
                    }
                    if !bottomTiles.isEmpty {
                        HStack(spacing: spacing) {
                            ForEach(bottomTiles, id: \.channel) { ch in
                                tile(for: ch, stream: .sub)
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

    // MARK: - Tile

    @ViewBuilder
    private func tile(for channel: ChannelStatus, stream: StreamKind, centerCrop: Bool = false) -> some View {
        LiveTileView(
            session: session,
            channel: channel,
            stream: stream,
            onTap: {
                if !isReordering {
                    selectedChannel = channel
                }
            },
            preferPreview: !liveGridEnabled,
            centerCropPreview: centerCrop,
            // 0.5.1 — multi-channel grid: force the camera-name
            // glass badge so users can tell adjacent tiles apart.
            // Single-camera detail views (`SingleChannelView`) leave
            // it false because the camera name is already in the
            // nav title.
            forcesNameBadge: true
        )
        .id(channel.channel)
        .opacity(draggingChannel == channel.channel ? 0.35 : 1.0)
        .jiggle(isActive: isReordering)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(channel.name ?? "Channel \(channel.channel + 1)")
        .accessibilityHint(isReordering ? "Drag to rearrange" : "Double-tap to view this camera")
        .accessibilityAddTraits(.isButton)
    }

    /// Pull-to-refresh handler. Re-fetches `cmd=Snap` for every visible
    /// channel in parallel (capped via the actor's in-flight
    /// deduplication, so even if a refresh is already running this
    /// pull just awaits it). No-op when the user has opted into live
    /// grids — there's nothing cached to refresh.
    private func refreshAllPreviews() async {
        let channels = visibleChannels
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                let cameraID = session.entry.id
                let channelID = channel.channel
                let session = self.session
                group.addTask {
                    guard let url = await session.snapshotURL(channel: channelID) else { return }
                    await CameraPreviewService.shared.refresh(
                        snapshotURL: url,
                        cameraID: cameraID,
                        channel: channelID
                    )
                }
            }
            await group.waitForAll()
        }
    }
}

/// Lightweight drag preview used while a tile is being dragged.
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

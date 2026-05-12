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
        ScrollView {
            LazyVGrid(columns: adaptiveColumns, spacing: 12) {
                ForEach(visibleChannels, id: \.channel) { channel in
                    let isDual = channel.isDualLens
                        || store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
                    tile(for: channel, stream: .sub)
                        .aspectRatio(isDual ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)
                }
            }
            .padding(12)
        }
    }

    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 600), spacing: 12)]
    }

    // MARK: - Fixed N×N grid

    private func fixedGrid(preset: GridPreset) -> some View {
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
            let tileWidth = max(0, (geo.size.width - totalHSpacing) / CGFloat(cols))
            let tileHeight = max(0, (geo.size.height - totalVSpacing) / CGFloat(rows))
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleChannels, id: \.channel) { channel in
                        tile(for: channel, stream: .sub)
                            .frame(width: tileWidth, height: tileHeight)
                    }
                }
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
    private func tile(for channel: ChannelStatus, stream: StreamKind) -> some View {
        LiveTileView(
            session: session,
            channel: channel,
            stream: stream,
            onTap: {
                if !isReordering {
                    selectedChannel = channel
                }
            }
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

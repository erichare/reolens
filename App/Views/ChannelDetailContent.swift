import SwiftUI
import AppKit
import ReolinkAPI
import ReolinkBaichuan
import AppShared

/// Shared single-camera UI: Live / Recordings / Settings tabs with a
/// control bar (PTZ, talkback, rotate, fullscreen). Used both when the
/// sidebar selects a channel (rendered inline inside `CameraDetailView`)
/// AND when a grid tile is tapped (rendered inside `RichViewerSheet`).
struct ChannelDetailContent: View {
    let session: CameraSession
    let channel: ChannelStatus
    @Environment(CameraStore.self) private var store
    @State private var tab: Tab = .live

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case live, recordings, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .live: "Live"
            case .recordings: "Recordings"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .live: "dot.radiowaves.left.and.right"
            case .recordings: "rectangle.stack.badge.play"
            case .settings: "gearshape"
            }
        }
    }

    @State private var pendingRecordingScroll: Date?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.label, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 0.5.0 Liquid Glass — Live / Recordings / Settings tab
            // picker reads as a glass header bar above the panel body.
            .reolensGlassToolbar()
            Divider()
            content
        }
        // Advertise this camera for Continuity / Handoff so the user
        // can pick it up on iPhone or iPad. AGENTS.md §11 — userInfo
        // carries only the UUID + channel index, never the host,
        // username, or display name beyond the `title`.
        .reolensCameraActivity(
            cameraID: session.entry.id,
            cameraName: session.entry.displayName,
            channelID: channel.channel
        )
        .onAppear { consumeRecordingScrollIfAny() }
        // ChannelDetailContent is re-used across channel changes (the
        // sidebar selection swaps which channel we render). Pick up
        // a freshly-arrived scroll target whenever the channel
        // changes.
        .onChange(of: channel.channel) { _, _ in
            consumeRecordingScrollIfAny()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .live:
            liveTab
        case .recordings:
            RecordingsView(
                session: session,
                channel: channel,
                scrollTarget: pendingRecordingScroll
            )
            .id(channel.channel)
        case .settings:
            ChannelSettingsView(session: session, channel: channel)
        }
    }

    /// If a notification tap is waiting to deep-link into this
    /// channel's Recordings tab, flip the tab AND copy the target
    /// time so the inner `RecordingsView` can auto-play the clip.
    private func consumeRecordingScrollIfAny() {
        if let at = store.consumePendingRecordingScroll(
            deviceID: session.entry.id,
            channel: channel.channel
        ) {
            tab = .recordings
            pendingRecordingScroll = at
        }
    }

    private var liveTab: some View {
        // Dual-lens cameras encode the two lenses side-by-side as a
        // stitched ~32:9 frame. Without an explicit aspect ratio the
        // detail view stretches that frame to fill the pane and the
        // image either crops aggressively or looks comically wide —
        // letterbox top + bottom is the right idiom for a fixed
        // aspect that doesn't match the window.
        let isDual = channel.isDualLens
            || store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
        return VStack(spacing: 0) {
            ZStack {
                Color.black
                LiveCameraTile(session: session, channel: channel, stream: .main)
                    .aspectRatio(isDual ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)
                    // Force SwiftUI to rebuild the tile when the user
                    // switches channels. Without an explicit identity,
                    // the persisting `@State` `player` keeps showing
                    // the previous channel's stream because the
                    // `.task(id: channel.channel)` guard sees
                    // `didStart=true` from the prior session and bails.
                    // The macOS grid uses the same idiom on its tiles.
                    .id(channel.channel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            PTZControlBar(session: session, channel: channel.channel)
            Spacer()
            TalkbackButton(session: session, channelID: UInt8(channel.channel))
            Spacer()
            rotationControls
            fullscreenToggle
        }
        .padding(12)
    }

    private var rotationControls: some View {
        // The control bar is shown above the main-stream tile, so its
        // Rotate action only affects main-stream rotation.
        let current = store.rotation(for: session.entry.id, channel: channel.channel, stream: .main)
        return HStack(spacing: 6) {
            Text("\(current)°").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button {
                store.rotateClockwise(deviceID: session.entry.id, channel: channel.channel, stream: .main)
            } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .help("Rotate the main feed 90° clockwise")
        }
    }

    /// Open a dedicated borderless fullscreen window. The previous
    /// approach (toggle native fullscreen on the host window + hide
    /// chrome) was unreliable — the host window's `toggleFullScreen`
    /// didn't always fire, and even when it did, only part of the
    /// chrome would collapse. A separate top-level `NSWindow` with
    /// just the video and an X to dismiss is what every consumer
    /// video app does, and it works regardless of how this view is
    /// hosted (inline detail pane, rich-viewer sheet, etc.).
    private var fullscreenToggle: some View {
        Button {
            FullscreenViewer.shared.presentSingle(
                session: session,
                channel: channel,
                store: store
            )
        } label: {
            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Show this camera feed full-screen — press Esc to exit")
        .keyboardShortcut("f", modifiers: [.command, .control])
    }
}

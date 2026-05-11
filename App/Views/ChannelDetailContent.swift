import SwiftUI
import ReolinkAPI
import ReolinkBaichuan

/// Shared single-camera UI: Live / Recordings / Settings tabs with a
/// control bar (PTZ, talkback, rotate, fullscreen). Used both when the
/// sidebar selects a channel (rendered inline inside `CameraDetailView`)
/// AND when a grid tile is tapped (rendered inside `RichViewerSheet`).
/// Pulling these into one view means both entry points expose the same
/// affordances — users don't have to learn two control surfaces.
struct ChannelDetailContent: View {
    let session: CameraSession
    let channel: ChannelStatus
    @Binding var columnVisibility: NavigationSplitViewVisibility
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

    private var sidebarHidden: Bool {
        columnVisibility == .detailOnly
    }

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
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .live:
            liveTab
        case .recordings:
            RecordingsView(session: session, channel: channel)
        case .settings:
            ChannelSettingsView(session: session, channel: channel)
        }
    }

    private var liveTab: some View {
        VStack(spacing: 0) {
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            Divider()
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            PTZControlBar(session: session, channel: channel.channel)
            Spacer()
            TalkbackButton(session: session, channelID: UInt8(channel.channel))
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

    /// Toggle between the standard split view (sidebar visible) and a
    /// "feed-only" view that hides the sidebar so the camera content fills
    /// the entire window. Works both when this view is hosted inline in
    /// `CameraDetailView` and inside the rich-viewer sheet — the binding
    /// is passed down from `ContentView`.
    private var fullscreenToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = sidebarHidden ? .automatic : .detailOnly
            }
        } label: {
            Label(
                sidebarHidden ? "Show sidebar" : "Fullscreen",
                systemImage: sidebarHidden
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
        }
        .help(sidebarHidden
              ? "Show the camera list again"
              : "Hide the camera list and fill the window with this feed")
    }
}

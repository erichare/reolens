import SwiftUI
import AppKit
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
    /// True when the user wants the camera content to fill the entire
    /// display. We do two things on enter: (a) take the window into
    /// native macOS fullscreen via `NSWindow.toggleFullScreen`, and (b)
    /// hide every piece of in-app chrome — tab picker, control bar,
    /// sidebar, header — so only the video frame is visible. On exit
    /// (button, the on-overlay close, or the OS-level toggle via green
    /// button / ⌘⌃F) we restore everything.
    @State private var isCameraFullscreen: Bool = false

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
            // Tab picker is part of the chrome we hide in fullscreen
            // (only the Live tab is shown there anyway).
            if !isCameraFullscreen {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Label(t.label, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            content
        }
        // Observe the actual OS fullscreen state so we stay in sync if the
        // user uses the green button or ⌘⌃F instead of our button.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if isCameraFullscreen { exitCameraFullscreen(animated: true) }
        }
    }

    @ViewBuilder
    private var content: some View {
        // In fullscreen we force the Live tab — Recordings and Settings
        // wouldn't be reachable anyway since the tab picker is hidden.
        if isCameraFullscreen {
            liveTab
        } else {
            switch tab {
            case .live:
                liveTab
            case .recordings:
                RecordingsView(session: session, channel: channel)
            case .settings:
                ChannelSettingsView(session: session, channel: channel)
            }
        }
    }

    private var liveTab: some View {
        VStack(spacing: 0) {
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .overlay(alignment: .topTrailing) {
                    if isCameraFullscreen { fullscreenExitOverlay }
                }
            if !isCameraFullscreen {
                Divider()
                controlBar
            }
        }
        // Pass-through host that exposes the underlying NSWindow so we can
        // call `toggleFullScreen` from the Fullscreen button.
        .background(WindowAccessor(isFullscreen: $isCameraFullscreen))
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

    /// Enter real OS-level fullscreen: the window goes full-display via
    /// `NSWindow.toggleFullScreen` and our in-app chrome (tab picker,
    /// control bar, sidebar) collapses so only the video frame is
    /// visible.
    private var fullscreenToggle: some View {
        Button {
            enterCameraFullscreen()
        } label: {
            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Show this camera feed full-screen — press Esc or the X overlay to exit")
        .keyboardShortcut("f", modifiers: [.command, .control])
    }

    /// Floating circular "exit" affordance overlaid on the top-right of
    /// the video during fullscreen. The video has no other chrome at that
    /// point, so this is the user's primary way out (along with ⌘⌃F).
    private var fullscreenExitOverlay: some View {
        Button {
            exitCameraFullscreen(animated: true)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.85), .black.opacity(0.55))
                .symbolRenderingMode(.palette)
        }
        .buttonStyle(.plain)
        .padding(12)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Exit fullscreen (Esc)")
    }

    private func enterCameraFullscreen() {
        guard !isCameraFullscreen else { return }
        isCameraFullscreen = true
        columnVisibility = .detailOnly
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func exitCameraFullscreen(animated: Bool) {
        guard isCameraFullscreen else { return }
        isCameraFullscreen = false
        // Only call toggleFullScreen if the window is actually in
        // fullscreen — when the user triggers exit via ⌘⌃F or the green
        // button, AppKit has already toggled the window for us and the
        // notification observer is what put us here, so we'd otherwise
        // toggle it back on.
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        withAnimation(animated ? .easeInOut(duration: 0.2) : nil) {
            columnVisibility = .automatic
        }
    }
}

/// Tiny `NSViewRepresentable` whose only job is to give us access to the
/// hosting `NSWindow` and observe its native-fullscreen transitions so
/// our `isFullscreen` state stays in sync even when the user toggles
/// fullscreen via AppKit (green window button / ⌘⌃F) instead of our
/// in-app button.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op; the parent's state drives the actions on the window
        // (we don't need to push state back through the view itself —
        // notifications handle that direction).
    }
}

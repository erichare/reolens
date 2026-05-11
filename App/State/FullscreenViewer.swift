import SwiftUI
import AppKit
import ReolinkAPI

/// Borderless full-screen viewer for a single camera feed — what "any
/// video app" does for fullscreen mode. Instead of fighting SwiftUI's
/// navigation stack and `NSWindow.toggleFullScreen` quirks, we open a
/// dedicated `NSWindow` sized to the main display, with the menu bar
/// and dock auto-hidden. The viewer hosts a `LiveCameraTile` against a
/// pure-black backdrop and an X overlay (Esc-bindable) to dismiss.
///
/// Lifecycle: `present(...)` creates the window if it's not already up;
/// `dismiss()` closes it and restores the normal app presentation
/// options. The window survives across SwiftUI re-renders because the
/// shared singleton holds the strong reference.
@MainActor
final class FullscreenViewer {
    static let shared = FullscreenViewer()

    private var window: NSWindow?
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    private init() {}

    func present(session: CameraSession, channel: ChannelStatus, store: CameraStore) {
        // Already showing — bring forward and stop.
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen.deepest!
        let frame = screen.frame
        let content = FullscreenViewerContent(
            session: session,
            channel: channel,
            onClose: { [weak self] in self?.dismiss() }
        )
        .environment(store)
        let host = NSHostingController(rootView: content)
        host.view.frame = NSRect(origin: .zero, size: frame.size)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.level = .mainMenu + 1
        // Stationary + can-join-all-spaces makes the fullscreen view
        // behave reasonably across spaces and on a secondary display.
        window.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces
        ]
        window.isOpaque = true
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.hasShadow = false
        window.titlebarAppearsTransparent = true

        // Hide the menu bar and Dock while the viewer is up. Restoring
        // these on dismiss is critical — otherwise the user gets a
        // half-broken Finder once they return.
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]

        window.makeKeyAndOrderFront(nil)
        window.center()
        // Re-snap to the screen frame after `center()` in case the
        // window manager nudged it.
        window.setFrame(frame, display: true)

        self.window = window
    }

    func dismiss() {
        guard let window else { return }
        if let prev = previousPresentationOptions {
            NSApp.presentationOptions = prev
            previousPresentationOptions = nil
        } else {
            NSApp.presentationOptions = []
        }
        window.orderOut(nil)
        window.contentViewController = nil
        self.window = nil
    }
}

/// SwiftUI view rendered inside the fullscreen window. Just the live
/// feed and an X to dismiss — no other chrome.
private struct FullscreenViewerContent: View {
    let session: CameraSession
    let channel: ChannelStatus
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .ignoresSafeArea()
            // Exit affordance. The Escape keyboard shortcut on the
            // button is what makes Esc actually dismiss the viewer —
            // bound directly to the button so it works as long as the
            // window is key.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.55))
                    .symbolRenderingMode(.palette)
                    .padding(20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Exit fullscreen (Esc)")
        }
    }
}

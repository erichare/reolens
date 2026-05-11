import SwiftUI
import AppKit
import ReolinkAPI

/// Borderless full-screen viewer — what "any video app" does for
/// fullscreen mode. Instead of fighting SwiftUI's navigation stack
/// and `NSWindow.toggleFullScreen` quirks, we open a dedicated
/// `NSWindow` sized to the main display, with the menu bar and dock
/// auto-hidden, hosting whatever SwiftUI content the caller hands us.
///
/// Two conveniences are layered on top:
///   - `presentSingle(session:channel:store:)` — one big camera feed
///     with an X overlay (Esc-bindable).
///   - `presentGrid(session:store:)` — the full multi-channel grid in
///     whatever layout preset the user picked, fullscreen.
///
/// Either path is idempotent — calling while a window is up just
/// brings it forward.
@MainActor
final class FullscreenViewer {
    static let shared = FullscreenViewer()

    private var window: NSWindow?
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    private init() {}

    // MARK: - Public entry points

    func presentSingle(session: CameraSession, channel: ChannelStatus, store: CameraStore) {
        present {
            SingleCameraFullscreen(
                session: session,
                channel: channel,
                onClose: { [weak self] in self?.dismiss() }
            )
            .environment(store)
        }
    }

    func presentGrid(session: CameraSession, store: CameraStore) {
        present {
            GridFullscreen(
                session: session,
                onClose: { [weak self] in self?.dismiss() }
            )
            .environment(store)
        }
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

    // MARK: - Window plumbing

    /// Generic presenter — accepts any SwiftUI view builder so the
    /// fullscreen window can show different content (single feed,
    /// full grid, …) without duplicating the NSWindow setup.
    private func present<Content: View>(@ViewBuilder content: () -> Content) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen.deepest!
        let frame = screen.frame
        let host = NSHostingController(rootView: AnyView(content()))
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
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces]
        window.isOpaque = true
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.hasShadow = false
        window.titlebarAppearsTransparent = true

        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]

        window.makeKeyAndOrderFront(nil)
        window.setFrame(frame, display: true)

        self.window = window
    }
}

// MARK: - Content views

/// One big camera tile + X exit overlay. The Esc keyboard shortcut is
/// attached directly to the button so dismiss works as long as the
/// fullscreen window is key.
private struct SingleCameraFullscreen: View {
    let session: CameraSession
    let channel: ChannelStatus
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .ignoresSafeArea()
            ExitButton(onClose: onClose)
        }
    }
}

/// The same `MultiChannelGridView` users see inline, but in a
/// borderless window. The control bar (preset picker, primary picker,
/// "Show sidebar" toggle) stays so the user can change layout while
/// fullscreen. An X overlay in the top-right corner dismisses.
private struct GridFullscreen: View {
    let session: CameraSession
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            MultiChannelGridView(session: session)
                .ignoresSafeArea()
            ExitButton(onClose: onClose)
        }
    }
}

private struct ExitButton: View {
    let onClose: () -> Void

    var body: some View {
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

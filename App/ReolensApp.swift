import SwiftUI
import AppKit
import AppShared

@main
struct ReolensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CameraStore()
    @State private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup("Reolens") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Wire notification-tap routing once on launch.
                    // NotificationTapDelegate is idempotent — multiple
                    // calls just re-assign the same delegate.
                    NotificationTapDelegate.install()
                    // Drain any pending intent (Shortcuts/Siri or a
                    // notification tap on cold launch).
                    store.applyPendingIntentFocus()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.applyPendingIntentFocus()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Replace the default About item with our own custom panel.
            // SwiftUI's `CommandGroup(replacing: .appInfo)` swaps out the
            // first item in the application menu without touching the
            // surrounding system items (Services, Hide, Quit, etc.).
            CommandGroup(replacing: .appInfo) {
                Button("About Reolens") {
                    showAboutPanel()
                }
            }
            // "Check for Updates…" sits just under the About item, which
            // is the macOS HIG-prescribed location for it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            SidebarCommands()
            ToolbarCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(minWidth: 480, minHeight: 320)
        }
    }

    /// Wraps our SwiftUI `AboutView` in a borderless `NSPanel`. We can't use
    /// `orderFrontStandardAboutPanel(options:)` because we want full control
    /// over the layout and links — the standard panel only takes a fixed
    /// set of keys (credits, version, etc.).
    @MainActor
    private func showAboutPanel() {
        AboutPanelController.shared.show()
    }
}

/// Singleton owner of the About panel so its window stays alive across
/// open/close cycles (the panel's `.releasedWhenClosed = false` means we
/// just hide it on close and re-show it on the next invocation).
@MainActor
final class AboutPanelController {
    static let shared = AboutPanelController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable]
        win.title = "About Reolens"
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftPM executables don't get a `.app` bundle, so AppKit treats the process
/// like a background tool by default — no Dock icon, no window focus. Force
/// `.regular` activation here so `swift run Reolens` actually shows a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CI smoke-test hook. Started with `--smoke-test`, the app boots
        // the SwiftUI scene normally (so the window + view tree
        // construct), then exits cleanly after a short delay. The
        // release workflow's smoke step launches the built `.app` with
        // this flag and asserts the process exits 0 within the window —
        // catching startup crashes that unit tests can't.
        let isSmokeTest = CommandLine.arguments.contains("--smoke-test")

        NSApp.activate(ignoringOtherApps: true)
        // Auto-request notification permission once, on the very first
        // launch where the OS hasn't yet recorded a decision. After the
        // user picks (allow / don't allow), the status flips to
        // `.authorized` or `.denied` and the `.notDetermined` guard
        // makes every subsequent launch a no-op — Apple's notification
        // center only ever prompts once anyway. Users who change their
        // mind later go through Settings → Notifications, which uses
        // the same `requestPermission` (when notDetermined) or deep-
        // links to System Settings (when denied).
        //
        // Skipped in smoke-test mode — we don't want to leave a
        // permission prompt hanging on a CI runner.
        if !isSmokeTest {
            Task { @MainActor in
                await EventNotifier.shared.refreshPermissionStatus()
                if EventNotifier.shared.permissionStatus == .notDetermined {
                    await EventNotifier.shared.requestPermission()
                }
            }
        }

        if isSmokeTest {
            // Give SwiftUI a runloop spin to construct the WindowGroup,
            // then exit. We bypass `NSApp.terminate(_:)` and call
            // `exit(0)` directly — terminate() can stall when the
            // SwiftUI scene hasn't fully wired up its delegates (which
            // is exactly the state a 2-second smoke launch is in), and
            // for a smoke test we just need a clean process-exit signal,
            // not graceful AppKit teardown.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

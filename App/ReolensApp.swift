import SwiftUI
import AppKit

@main
struct ReolensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CameraStore()

    var body: some Scene {
        WindowGroup("Reolens") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            ToolbarCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(minWidth: 480, minHeight: 320)
        }
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
        Task { @MainActor in
            await EventNotifier.shared.refreshPermissionStatus()
            if EventNotifier.shared.permissionStatus == .notDetermined {
                await EventNotifier.shared.requestPermission()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

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
        // Refresh the notifier's authorization-status mirror. On first
        // launch this also drives the SwiftUI permission row in Settings
        // → Notifications to show "Request permission". We don't auto-
        // prompt at launch — users get to choose whether to opt in
        // (and from where) via the Settings UI.
        Task { @MainActor in
            await EventNotifier.shared.refreshPermissionStatus()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

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
                    // Drain any pending intent the user fired before
                    // the app was running (Shortcuts/Siri or a
                    // notification tap on cold launch). The delegate
                    // itself is installed in AppDelegate so it's in
                    // place before iOS/macOS dispatches a launch-time
                    // notification response.
                    store.applyPendingIntentFocus()
                    // Install the menu-bar status item lazily, based on
                    // the user's persisted preference. AGENTS.md §10 —
                    // we never add a menu-bar icon without the user
                    // opting in.
                    MenuBarController.shared.syncFromDefaults(store: store)
                    // 0.5.0 Theme A5 — reconcile the daily overnight
                    // digest with the user's current settings. Idle
                    // until the user opts in; then a single
                    // `UNCalendarNotificationTrigger` (repeats: true)
                    // fires at the configured hour without needing
                    // any background mode.
                    Task { await DigestScheduler.shared.reconcileSchedule() }
                    // 0.5.1 — proactively fetch a snapshot for every
                    // non-battery camera in the background so first-
                    // open tiles aren't stuck on "No preview yet".
                    // Battery cameras stay opt-in (waking them
                    // periodically just for a still would drain
                    // battery for low value).
                    CameraPreviewPrefetcher.shared.start(store: store)
                }
                .onContinueUserActivity(CameraContinuity.cameraDetailActivityType) { activity in
                    if CameraContinuity.handle(activity: activity) {
                        store.applyPendingIntentFocus()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.applyPendingIntentFocus()
                    // 0.5.1 — re-sweep on activation so a user
                    // returning to the app after a while sees fresh
                    // tiles rather than waiting for the next 15-min
                    // periodic cycle.
                    Task { await CameraPreviewPrefetcher.shared.sweepNow() }
                }
                // Drain when a focus request is written AFTER the
                // scene's launch `.task` ran — typically the
                // cold-launch-via-notification-tap path, where
                // `NotificationTapDelegate.didReceive` fires after
                // `applicationDidFinishLaunching` and the scene is
                // already `.active`, so `didBecomeActiveNotification`
                // doesn't re-fire.
                .onReceive(NotificationCenter.default.publisher(for: AppIntentFocus.didUpdate)) { _ in
                    store.applyPendingIntentFocus()
                }
                // TLS pinning mismatches surface as a global sheet so
                // they can't be missed in any specific view. The sheet
                // either records the new cert (user "trusts new") or
                // cancels (connection stays rejected). AGENTS.md §3.
                .sheet(item: Binding(
                    get: { store.pendingTrustChange },
                    set: { store.pendingTrustChange = $0 }
                )) { request in
                    TrustChangedSheet(request: request)
                        .environment(store)
                }
                // 0.5.0 Theme A5 — digest sheet, presented when a
                // digest notification tap routes through
                // `applyPendingIntentFocus()`.
                .sheet(item: Binding<DigestDaySheet?>(
                    get: { store.pendingDigestDay.map { DigestDaySheet(day: $0) } },
                    set: { _ in store.pendingDigestDay = nil }
                )) { sheet in
                    DigestDetailView(requestedDay: sheet.day)
                }
                // Keychain write failures bubble up here as an alert
                // so the user sees them instead of bouncing back to
                // "No password on this Mac" silently after entering
                // a password.
                .alert(
                    "Couldn't save password",
                    isPresented: Binding(
                        get: { store.passwordSaveError != nil },
                        set: { isShown in if !isShown { store.passwordSaveError = nil } }
                    ),
                    presenting: store.passwordSaveError
                ) { _ in
                    Button("OK", role: .cancel) {
                        store.passwordSaveError = nil
                    }
                } message: { err in
                    Text(err.message)
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        // 0.5.0 — secondary scene for "Open in New Window" on a
        // single camera. `WindowGroup(for: ReolensScene.self)` opens a
        // fresh window keyed by the scene value; SwiftUI handles
        // multi-window state automatically. Used by the sidebar
        // context-menu's "Open in New Window" item — see
        // [CameraListView.swift].
        WindowGroup(for: ReolensScene.self) { $scene in
            CameraSceneHost(scene: scene ?? .main)
                .environment(store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified(showsTitle: true))

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

/// 0.5.0 Theme A5 — `Identifiable` wrapper for `Date` so the digest
/// sheet's `.sheet(item:)` binding has a stable identity that matches
/// the requested-day epoch.
private struct DigestDaySheet: Identifiable {
    let day: Date
    var id: TimeInterval { day.timeIntervalSince1970 }
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
        // Install the notification-tap delegate as early as possible
        // so a cold-launch tap on an alarm notification is routed
        // correctly. willFinishLaunching is the earliest hook NSApp
        // offers; setting `UNUserNotificationCenter.delegate` here
        // guarantees it's in place before iOS dispatches any
        // pending response.
        NotificationTapDelegate.install()
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

    /// When the user has opted into menu-bar mode (Settings → General →
    /// "Run in the menu bar when closed", 0.4.0), closing the last
    /// window leaves the app running so the menu-bar item can keep
    /// posting motion notifications. AGENTS.md §10 — only honors the
    /// flag the user explicitly flipped on, so default behavior
    /// (terminate on last window close) is unchanged.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: MenuBarController.menuBarModeKey)
    }
}

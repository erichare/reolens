import SwiftUI
import UIKit
import AppShared

@main
struct ReolensiOSApp: App {
    /// `UIApplicationDelegateAdaptor` so we can install the
    /// `NotificationTapDelegate` during `didFinishLaunchingWithOptions`.
    /// That timing is essential for cold-launch notification taps —
    /// installing in scene `.task` is too late, because iOS attempts
    /// to dispatch the tap response before the scene has even
    /// mounted.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared camera model. Lives for the lifetime of the app and is
    /// injected into every view via `.environment(_:)`. The store wakes
    /// up the iCloud Drive sync helper in its initializer, so cameras
    /// added on the Mac (or any other signed-in device) appear here
    /// without any explicit pull on launch.
    @State private var store = CameraStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    // Drain any pending intent the user fired before
                    // the app was running (Shortcuts/Siri or a
                    // notification tap on a cold launch — both write
                    // to the same UserDefaults pointer via
                    // `AppIntentFocus.request`; `CameraStore` consumes
                    // it here). The delegate itself is already
                    // installed by AppDelegate.
                    store.applyPendingIntentFocus()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.applyPendingIntentFocus()
                    }
                }
        }
    }
}

/// `UIApplicationDelegate` that installs the notification-tap delegate
/// early in the launch sequence. SwiftUI scenes mount AFTER
/// `didFinishLaunchingWithOptions` returns, so installing in
/// `.task` could miss a cold-launch tap — the response may be
/// dispatched before the scene appears. Doing it here guarantees the
/// delegate is in place no matter how the app comes up.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationTapDelegate.install()
        return true
    }
}


import SwiftUI
import AppShared

@main
struct ReolensiOSApp: App {
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
                    // Drain any "Open Camera" intent the user fired before
                    // the app was running (Shortcuts/Siri sets a focus
                    // pointer in UserDefaults; CameraStore consumes it).
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

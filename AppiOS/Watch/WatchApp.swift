import SwiftUI
import AppWatch

/// `@main` entry point for the Reolens watchOS companion app.
///
/// All real surface lives in `AppWatch.WatchRootView`. Keeping the
/// app shell empty here means the watch target builds with a single
/// Swift file and the library product wired through SPM. See
/// `Sources/AppWatch/README.md` for the architecture overview.
@main
struct ReolensWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

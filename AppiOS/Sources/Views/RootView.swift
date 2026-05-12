import SwiftUI
import AppShared

/// Top-level shell. Picks the right navigation paradigm for the device:
///
/// - iPhone (compact horizontal size class) gets a four-tab `TabView`.
///   Each tab is a stand-alone NavigationStack so deep links inside one
///   tab don't unwind when the user switches to another.
/// - iPad and large iPhones in landscape get a three-column
///   `NavigationSplitView`, mirroring the Mac sidebar.
///
/// Size-class branching is the right granularity here: the same iPhone
/// rotated to landscape doesn't get the iPad layout (its regular width
/// is still narrow). iPadOS multi-window scenes get the iPad layout in
/// every Stage Manager configuration.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            iPhoneTabShell()
        } else {
            iPadSplitShell()
        }
    }
}

#if !os(macOS)
import SwiftUI

/// Top-level scene for the Reolens watch app. The companion iPhone
/// app must be running for fresh data (live snapshot polling reads
/// the App Group container that the iPhone's widget pipeline keeps
/// up-to-date). Watch-only behavior: notifications still arrive via
/// Apple's automatic iPhone → Watch forwarding.
public struct WatchRootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            WatchCameraListView()
                .navigationTitle("Reolens")
        }
    }
}
#endif

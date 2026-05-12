import SwiftUI
import AppShared

/// iPhone navigation paradigm: four tabs, each its own `NavigationStack`
/// so deep links into a tab don't get wiped when the user switches
/// elsewhere.
///
/// The Live tab takes a `NavigationPath` binding so an "Open Camera"
/// Shortcut/Siri intent can route directly to a camera's detail view
/// when the app launches in response to the intent. Other tabs keep
/// their default-managed stacks.
struct iPhoneTabShell: View {
    @Environment(CameraStore.self) private var store

    enum Tab: Hashable {
        case live
        case recordings
        case devices
        case settings
    }

    @State private var selectedTab: Tab = .live
    @State private var liveTabPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $liveTabPath) {
                LivePlaceholderView()
                    .navigationTitle("Live")
                    .navigationDestination(for: CameraEntry.self) { entry in
                        if let session = store.session(for: entry.id) {
                            CameraDetailView(session: session)
                        } else {
                            ContentUnavailableView {
                                Label("No password on this device", systemImage: "key.slash")
                            } description: {
                                Text("\(entry.displayName) was added on another device. Enter the password to stream from it.")
                            }
                        }
                    }
            }
            .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            .tag(Tab.live)

            NavigationStack {
                RecordingsPlaceholderView()
                    .navigationTitle("Recordings")
            }
            .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
            .tag(Tab.recordings)

            NavigationStack {
                DevicesPlaceholderView()
                    .navigationTitle("Devices")
            }
            .tabItem { Label("Devices", systemImage: "video.fill") }
            .tag(Tab.devices)

            NavigationStack {
                SettingsPlaceholderView()
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
        .onChange(of: store.pendingIntentNavigationDeviceID) { _, newID in
            guard let newID,
                  let entry = store.cameras.first(where: { $0.id == newID })
            else { return }
            // Switch to Live and push the camera detail. Reset the path
            // first so the user lands on the new camera at depth 1,
            // not stacked on top of whatever they were last viewing.
            selectedTab = .live
            liveTabPath = NavigationPath()
            liveTabPath.append(entry)
            store.pendingIntentNavigationDeviceID = nil
        }
    }
}

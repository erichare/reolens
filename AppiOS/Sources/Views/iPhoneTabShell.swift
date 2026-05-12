import SwiftUI
import AppShared

/// iPhone navigation paradigm: four tabs, each its own `NavigationStack`
/// so deep links into a tab don't get wiped when the user switches
/// elsewhere. The placeholder views are filled in in Phase 4.
struct iPhoneTabShell: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        TabView {
            NavigationStack {
                LivePlaceholderView()
                    .navigationTitle("Live")
            }
            .tabItem { Label("Live", systemImage: "play.rectangle.fill") }

            NavigationStack {
                RecordingsPlaceholderView()
                    .navigationTitle("Recordings")
            }
            .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }

            NavigationStack {
                DevicesPlaceholderView()
                    .navigationTitle("Devices")
            }
            .tabItem { Label("Devices", systemImage: "video.fill") }

            NavigationStack {
                SettingsPlaceholderView()
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

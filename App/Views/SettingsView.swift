import SwiftUI

struct SettingsView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            developerTab
                .tabItem { Label("Developer", systemImage: "hammer") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }

    private var generalTab: some View {
        Form {
            LabeledContent("Cameras configured") {
                Text("\(store.cameras.count)")
            }
            Text("Settings UI is a placeholder. Camera-specific options will move here (snapshot interval, polling cadence, preferred stream).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var developerTab: some View {
        @Bindable var store = store
        return Form {
            Section {
                Toggle("Developer mode", isOn: $store.developerMode)
                Text("Surfaces diagnostic UI for debugging: Raw JSON popovers in the recordings view and other low-level inspection tools. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Text("Reolens")
                .font(.title2.weight(.semibold))
            Text("A modern, native macOS client for Reolink cameras and NVRs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

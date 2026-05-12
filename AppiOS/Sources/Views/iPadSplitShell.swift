import SwiftUI
import AppShared

/// iPad navigation paradigm: three-column `NavigationSplitView`.
///
/// - Column 1 (sidebar): top-level sections (Live, Recordings, Devices,
///   Settings) plus a device list grouped under "Cameras".
/// - Column 2 (content): list/grid for the selected section.
/// - Column 3 (detail): the chosen camera / recording / setting page.
///
/// Mirrors the macOS app's layout intentionally so users moving between
/// Mac and iPad don't have to relearn the model. The placeholder views
/// are filled in in Phase 4.
struct iPadSplitShell: View {
    @Environment(CameraStore.self) private var store
    @State private var selectedSection: SidebarSection? = .live

    enum SidebarSection: Hashable {
        case live
        case recordings
        case settings
        case device(UUID)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("Reolens") {
                    Label("Live", systemImage: "play.rectangle.fill")
                        .tag(SidebarSection.live)
                    Label("Recordings", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.recordings)
                    Label("Settings", systemImage: "gear")
                        .tag(SidebarSection.settings)
                }
                if !store.cameras.isEmpty {
                    Section("Cameras") {
                        ForEach(store.cameras) { entry in
                            Label(entry.displayName, systemImage: "video.fill")
                                .tag(SidebarSection.device(entry.id))
                        }
                    }
                }
            }
            .navigationTitle("Reolens")
        } content: {
            sectionContent
        } detail: {
            Text("Select a camera")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .live, .none:
            LivePlaceholderView()
                .navigationTitle("Live")
        case .recordings:
            RecordingsPlaceholderView()
                .navigationTitle("Recordings")
        case .settings:
            SettingsPlaceholderView()
                .navigationTitle("Settings")
        case .device(let id):
            if let entry = store.cameras.first(where: { $0.id == id }) {
                DevicePlaceholderView(entry: entry)
                    .navigationTitle(entry.displayName)
            } else {
                Text("Camera not found")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

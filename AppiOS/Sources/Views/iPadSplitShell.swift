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
/// Mac and iPad don't have to relearn the model.
struct iPadSplitShell: View {
    @Environment(CameraStore.self) private var store
    @State private var selectedSection: SidebarSection? = .live
    @State private var showingAdd = false
    @State private var isReorderingCameras: Bool = false
    @State private var draggingDevice: UUID?

    enum SidebarSection: Hashable {
        case live
        case recordings
        case devices
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
                    Label("Devices", systemImage: "video.fill")
                        .tag(SidebarSection.devices)
                    Label("Settings", systemImage: "gear")
                        .tag(SidebarSection.settings)
                }
                if !store.cameras.isEmpty {
                    Section("Cameras") {
                        ForEach(store.orderedCameras()) { entry in
                            Label(entry.displayName, systemImage: "video.fill")
                                .tag(SidebarSection.device(entry.id))
                                .opacity(draggingDevice == entry.id ? 0.35 : 1.0)
                                .jiggle(isActive: isReorderingCameras)
                                .onLongPressGesture(minimumDuration: 0.7) {
                                    if !isReorderingCameras {
                                        withAnimation(.easeIn(duration: 0.2)) {
                                            isReorderingCameras = true
                                        }
                                    }
                                }
                                .draggable(DeviceDragPayload(deviceID: entry.id)) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "video.fill")
                                            .foregroundStyle(.white)
                                        Text(entry.displayName)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
                                    .onAppear { draggingDevice = entry.id }
                                    .onDisappear { draggingDevice = nil }
                                }
                                .dropDestination(for: DeviceDragPayload.self) { payload, _ in
                                    guard let source = payload.first, source.deviceID != entry.id else { return false }
                                    return store.reorderCamera(source: source.deviceID, before: entry.id)
                                }
                        }
                    }
                }
            }
            .navigationTitle("Reolens")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if isReorderingCameras {
                        Button("Done") {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isReorderingCameras = false
                            }
                        }
                    } else {
                        Menu {
                            Button {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    isReorderingCameras = true
                                }
                            } label: {
                                Label("Rearrange Cameras", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                            .disabled(store.cameras.count < 2)
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        Button {
                            showingAdd = true
                        } label: {
                            Label("Add Camera", systemImage: "plus")
                        }
                        .accessibilityLabel("Add Camera")
                    }
                }
            }
        } content: {
            sectionContent
        } detail: {
            Text("Select a camera")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingAdd) {
            AddCameraView()
        }
        .onChange(of: store.pendingIntentNavigationDeviceID) { _, newID in
            // An "Open Camera" Shortcut/Siri intent fired. Route to the
            // requested camera in the content/detail column and clear
            // the one-shot pointer so the next change re-fires.
            if let newID {
                selectedSection = .device(newID)
                store.pendingIntentNavigationDeviceID = nil
            }
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
        case .devices:
            DevicesPlaceholderView()
                .navigationTitle("Devices")
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

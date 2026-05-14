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
    @State private var health = CameraNotificationHealth.shared
    /// 0.6.0 — gates the cold-launch "restore last camera"
    /// selection so a SwiftUI re-render (every time `store.cameras`
    /// updates) doesn't keep overriding the user's manual
    /// navigation back to .live / .recordings / etc.
    @State private var restoredLastCamera: Bool = false

    enum SidebarSection: Hashable {
        case live
        case recordings
        case devices
        case settings
        case device(UUID)
        /// A specific channel under a multi-channel hub / NVR.
        /// macOS sidebar has had this since 0.3 via
        /// `DeviceSidebarRow`'s DisclosureGroup — iPad caught up in
        /// 0.4.1 so a Reolink hub's individual cameras are
        /// addressable from the sidebar.
        case channel(deviceID: UUID, channel: Int)
    }

    var body: some View {
        // 0.5.1 — collapsed from a three-column NavigationSplitView
        // to a two-column one. The previous third column always
        // showed "Select a camera" and never updated (no destination
        // was wired up), which manifested as the user's "panel on the
        // right that stays all the time" complaint. The new layout
        // shows the sidebar + a detail column that swaps with
        // `selectedSection`. The NavigationStack inside the detail
        // column is keyed off `selectedSection` so any sidebar tap
        // hard-resets navigation state — matching the user's request
        // that selecting a row always lands on a fresh Live view.
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("Reolens") {
                    Label("Live", systemImage: "play.rectangle.fill")
                        .tag(SidebarSection.live)
                        .contentShape(.rect)
                    Label("Recordings", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.recordings)
                        .contentShape(.rect)
                    Label("Devices", systemImage: "video.fill")
                        .tag(SidebarSection.devices)
                        .contentShape(.rect)
                    Label("Settings", systemImage: "gear")
                        .tag(SidebarSection.settings)
                        .contentShape(.rect)
                }
                if !store.cameras.isEmpty {
                    Section("Cameras") {
                        ForEach(store.orderedCameras()) { entry in
                            cameraRow(for: entry)
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
        } detail: {
            NavigationStack {
                sectionContent
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
                    .navigationDestination(for: CameraChannelTarget.self) { target in
                        if let session = store.session(for: target.deviceID),
                           let channel = session.channels.first(where: { $0.channel == target.channel }) {
                            SingleChannelView(session: session, channel: channel)
                                .id(target)
                        } else if let session = store.session(for: target.deviceID) {
                            CameraDetailView(session: session, focusedChannel: target.channel)
                        } else {
                            ContentUnavailableView("Camera not found", systemImage: "video.slash")
                        }
                    }
            }
            // Re-key the entire NavigationStack on any sidebar change
            // so the user lands on the section's root view every time
            // — no stale push state from a previous section.
            .id(selectedSection)
        }
        .sheet(isPresented: $showingAdd) {
            AddCameraView()
        }
        .task {
            // 0.6.0 — restore the most-recently-viewed camera on
            // cold launch. App-Intent navigation wins over
            // restoration. Guarded by `restoredLastCamera` so a
            // SwiftUI re-render doesn't keep overriding the user's
            // current selection.
            guard !restoredLastCamera else { return }
            restoredLastCamera = true
            guard store.pendingIntentNavigation == nil,
                  let lastID = store.preferences.lastViewedCameraID,
                  store.cameras.contains(where: { $0.id == lastID }) else { return }
            selectedSection = .device(lastID)
        }
        .onChange(of: selectedSection) { _, newValue in
            // 0.6.0 — persist whenever the user navigates into a
            // device or channel section so the next launch lands
            // here. Non-camera sections (Live, Recordings, Devices,
            // Settings) don't clear the memory — the user picking
            // "Recordings" briefly shouldn't lose their last
            // camera; only an explicit camera switch should.
            switch newValue {
            case .device(let id):
                store.preferences.lastViewedCameraID = id
            case .channel(let id, _):
                store.preferences.lastViewedCameraID = id
            case .live, .recordings, .devices, .settings, nil:
                break
            }
        }
        .onChange(of: store.pendingIntentNavigation) { _, target in
            guard let target else { return }
            switch target {
            case .liveCamera(let deviceID):
                selectedSection = .device(deviceID)
            case .recording(let deviceID, let channelID, _):
                // Drill straight into the channel's detail; the inner
                // SingleChannelView reads `pendingRecordingScroll`
                // off the store on appear, flips to its Recordings
                // tab, and auto-plays the closest clip.
                selectedSection = .channel(deviceID: deviceID, channel: channelID)
            case .digest:
                // 0.5.0 Theme A5 — the digest detail sheet is
                // presented at the app entry point via a binding
                // on `store.pendingDigestDay`. Sidebar selection
                // stays as-is.
                break
            }
            store.pendingIntentNavigation = nil
        }
    }

    /// Sidebar row for a single device. Multi-channel hubs / NVRs
    /// render as a `DisclosureGroup` so the user can drill into a
    /// specific channel directly from the sidebar — mirrors how the
    /// macOS `DeviceSidebarRow` has worked since 0.3.
    @ViewBuilder
    private func cameraRow(for entry: CameraEntry) -> some View {
        let session = store.session(for: entry.id)
        // Reolink Home Hub reports all 24 paired-camera slots even
        // when most are empty. Empty slots have no name and no
        // typeInfo — filter so the sidebar doesn't fill up with
        // 24 useless "Channel N" entries.
        let channels = (session?.channels ?? []).filter { ch in
            (ch.name?.isEmpty == false) || (ch.typeInfo?.isEmpty == false)
        }
        // 0.5.1 — drag-to-reorder is gated on `isReorderingCameras`
        // so the modifier doesn't intercept ordinary taps. Reorder
        // mode is entered from the toolbar's "Rearrange Cameras"
        // menu; the previous long-press shortcut added gesture
        // latency to every tap on a hub label. `.dropDestination`
        // stays always-on (inert outside an active drag).
        let baseLabel = Label(entry.displayName, systemImage: "video.fill")
            .badge(health.badgeText(for: entry.id) ?? "")
            .opacity(draggingDevice == entry.id ? 0.35 : 1.0)
            .jiggle(isActive: isReorderingCameras)
            .dropDestination(for: DeviceDragPayload.self) { payload, _ in
                guard let source = payload.first, source.deviceID != entry.id else { return false }
                return store.reorderCamera(source: source.deviceID, before: entry.id)
            }
        let deviceLabel = Group {
            if isReorderingCameras {
                baseLabel.draggable(DeviceDragPayload(deviceID: entry.id)) {
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
            } else {
                baseLabel
            }
        }

        if channels.count > 1 {
            DisclosureGroup(isExpanded: bindingForExpansion(deviceID: entry.id)) {
                ForEach(channels, id: \.channel) { ch in
                    Label(ch.name ?? "Channel \(ch.channel + 1)", systemImage: ch.isAsleep ? "moon.zzz" : "video.fill")
                        .tag(SidebarSection.channel(deviceID: entry.id, channel: ch.channel))
                        // 0.5.0 Theme A4 — long-press context menu
                        // on iPadOS surfaces "Open in New Window"
                        // which opens this specific channel as its
                        // own scene. Drives Stage Manager / multi-
                        // window layouts.
                        .contextMenu {
                            OpenInNewSceneButton(scene: .camera(id: entry.id, channel: ch.channel))
                        }
                }
            } label: {
                deviceLabel
                    .tag(SidebarSection.device(entry.id))
                    .contextMenu {
                        OpenInNewSceneButton(scene: .camera(id: entry.id, channel: channels.first?.channel ?? 0))
                    }
            }
        } else {
            deviceLabel
                .tag(SidebarSection.device(entry.id))
                .contextMenu {
                    OpenInNewSceneButton(scene: .camera(id: entry.id, channel: channels.first?.channel ?? 0))
                }
        }
    }

    /// 0.5.0 Theme A4 — iPadOS "Open in New Window". Opens a fresh
    /// scene via the shared `WindowGroup(for: ReolensScene.self)`
    /// declared on `ReolensiOSApp`. iPadOS surfaces this as a new
    /// scene the user can drag into Stage Manager's tile grid.
    private struct OpenInNewSceneButton: View {
        let scene: ReolensScene
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Open in New Window", systemImage: "rectangle.badge.plus") {
                openWindow(value: scene)
            }
        }
    }

    /// 0.5.1 — hubs auto-expand by default; collapse state syncs
    /// across devices through `HubExpansionStore` (iCloud KV).
    private func bindingForExpansion(deviceID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.hubExpansion.isExpanded(deviceID: deviceID) },
            set: { store.hubExpansion.setExpanded($0, for: deviceID) }
        )
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
        case .channel(let deviceID, let channelID):
            if let entry = store.cameras.first(where: { $0.id == deviceID }),
               let session = store.session(for: deviceID),
               let channel = session.channels.first(where: { $0.channel == channelID }) {
                SingleChannelView(session: session, channel: channel)
                    .navigationTitle(channel.name ?? "Channel \(channelID + 1)")
                    // Belt-and-suspenders so SwiftUI rebuilds the
                    // detail when the user picks a different channel
                    // — same idiom we just added to macOS
                    // `ChannelDetailContent`.
                    .id(SidebarSection.channel(deviceID: deviceID, channel: channelID))
            } else if let entry = store.cameras.first(where: { $0.id == deviceID }) {
                // Session not ready yet (still connecting). Surface a
                // placeholder rather than blanking the detail pane.
                DevicePlaceholderView(entry: entry)
                    .navigationTitle(entry.displayName)
            } else {
                Text("Camera not found")
                    .foregroundStyle(.secondary)
            }
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

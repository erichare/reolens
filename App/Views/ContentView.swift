import SwiftUI
import AppShared

struct ContentView: View {
    @Environment(CameraStore.self) private var store
    @State private var showingAddCamera = false
    @State private var passwordEntryEntry: CameraEntry?

    var body: some View {
        // Sidebar visibility is driven by the native toolbar toggle that
        // `SidebarCommands()` installs in `ReolensApp`; we don't need to
        // own a `columnVisibility` binding anymore since nothing else in
        // the app drives that state.
        NavigationSplitView {
            CameraListView(showingAddCamera: $showingAddCamera)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            // 0.5.1 — force the detail pane to rebuild whenever the
            // sidebar selection changes. Without an explicit identity,
            // SwiftUI reuses `ChannelDetailContent.@State tab` across
            // (Camera A → Camera B) switches, so the user would see the
            // previous channel's tab + still-streaming player while the
            // new channel was selected. The user's explicit ask is for
            // the detail to land on Live every time a row is clicked.
            detailContent
                .id(store.selection)
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet { entry, password in
                store.add(entry, password: password)
            }
        }
        .sheet(item: $passwordEntryEntry) { entry in
            EnterPasswordSheet(entry: entry)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reolensSwitchToCamera)) { note in
            // 0.6.1 — ⌘1..⌘9 jumps to the n-th camera in the store.
            // The Camera menu posts this with userInfo["index"] as a
            // zero-based Int; we bounds-check against the live list
            // so an out-of-range key is a no-op (better than a beep
            // and no feedback).
            guard let index = note.userInfo?["index"] as? Int,
                  index >= 0, index < store.cameras.count else { return }
            let camera = store.cameras[index]
            store.selection = .device(camera.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reolensRefreshLiveTiles)) { _ in
            // 0.6.1 — ⌘R refreshes every camera's snapshot through the
            // shared prefetcher. Reuses the existing background sweep
            // path so this menu item doesn't introduce a parallel
            // refresh codepath.
            Task { await CameraPreviewPrefetcher.shared.sweepNow() }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selection = store.selection,
           let session = store.session(for: selection.deviceID) {
            CameraDetailView(
                session: session,
                focusedChannel: selection.channel
            )
        } else if let selection = store.selection,
                  let entry = store.cameras.first(where: { $0.id == selection.deviceID }) {
            // A device is selected but has no session — almost always
            // because it synced in from another Apple device and the
            // password isn't on this Mac yet.
            MissingPasswordDetailView(entry: entry) {
                passwordEntryEntry = entry
            }
        } else {
            EmptyDetailView(showingAddCamera: $showingAddCamera)
        }
    }
}

struct EmptyDetailView: View {
    @Binding var showingAddCamera: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No device selected", systemImage: "video.slash")
        } description: {
            Text("Add a Reolink camera, NVR, or Home Hub to begin.")
        } actions: {
            Button("Add Device…") { showingAddCamera = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct MissingPasswordDetailView: View {
    let entry: CameraEntry
    let onEnterPassword: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No password on this Mac", systemImage: "key.slash")
        } description: {
            Text("\(entry.displayName) was added on another device. Enter the password on this Mac to start streaming.")
        } actions: {
            Button("Enter Password…", action: onEnterPassword)
                .buttonStyle(.borderedProminent)
        }
    }
}

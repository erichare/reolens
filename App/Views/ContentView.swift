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
            detailContent
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet { entry, password in
                store.add(entry, password: password)
            }
        }
        .sheet(item: $passwordEntryEntry) { entry in
            EnterPasswordSheet(entry: entry)
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

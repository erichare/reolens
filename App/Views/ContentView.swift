import SwiftUI

struct ContentView: View {
    @Environment(CameraStore.self) private var store
    @State private var showingAddCamera = false

    var body: some View {
        // Sidebar visibility is driven by the native toolbar toggle that
        // `SidebarCommands()` installs in `ReolensApp`; we don't need to
        // own a `columnVisibility` binding anymore since nothing else in
        // the app drives that state.
        NavigationSplitView {
            CameraListView(showingAddCamera: $showingAddCamera)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let selection = store.selection,
               let session = store.session(for: selection.deviceID) {
                CameraDetailView(
                    session: session,
                    focusedChannel: selection.channel
                )
            } else {
                EmptyDetailView(showingAddCamera: $showingAddCamera)
            }
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet { entry, password in
                store.add(entry, password: password)
            }
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

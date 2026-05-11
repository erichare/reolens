import SwiftUI

struct ContentView: View {
    @Environment(CameraStore.self) private var store
    @State private var showingAddCamera = false
    /// Drives the sidebar's collapse animation. When `.detailOnly` the
    /// sidebar is hidden and the camera detail fills the entire window,
    /// which is what the "Fullscreen" action wires up to.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CameraListView(showingAddCamera: $showingAddCamera)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let selection = store.selection,
               let session = store.session(for: selection.deviceID) {
                CameraDetailView(
                    session: session,
                    focusedChannel: selection.channel,
                    columnVisibility: $columnVisibility
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

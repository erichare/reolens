import SwiftUI
import AppShared

/// Real tab content for Phase 4 (Live, Devices) and placeholders for
/// Phase 5/6 (Recordings, Settings).

/// Live tab — lists cameras and lets the user tap into a single
/// camera's detail (multi-channel grid or single-channel view).
struct LivePlaceholderView: View {
    @Environment(CameraStore.self) private var store
    @State private var showingAdd = false
    @State private var passwordEntryEntry: CameraEntry?
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if store.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No Cameras", systemImage: "video.slash")
                } description: {
                    Text("Add a camera to start streaming. The camera list syncs from your other Reolens devices via iCloud.")
                } actions: {
                    Button("Add Camera…") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(store.orderedCameras(matching: searchText)) { entry in
                    NavigationLink {
                        if let session = store.session(for: entry.id) {
                            CameraDetailView(session: session)
                        } else {
                            ContentUnavailableView {
                                Label("No password on this device", systemImage: "key.slash")
                            } description: {
                                Text("\(entry.displayName) was added on another device. Enter the password on this device to stream from it.")
                            } actions: {
                                Button("Enter Password") { passwordEntryEntry = entry }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } label: {
                        CameraRow(entry: entry)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.remove(entry.id)
                        }
                        Button("Enter Password", systemImage: "key.fill") {
                            passwordEntryEntry = entry
                        }
                        .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Enter Password", systemImage: "key.fill") {
                            passwordEntryEntry = entry
                        }
                        if store.session(for: entry.id) != nil {
                            Button("Reconnect", systemImage: "arrow.clockwise.circle") {
                                store.reconnect(entry.id)
                            }
                        }
                        Divider()
                        Button("Delete Camera", systemImage: "trash", role: .destructive) {
                            store.remove(entry.id)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("Add Camera", systemImage: "plus")
                }
                .accessibilityLabel("Add Camera")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCameraView()
        }
        .sheet(item: $passwordEntryEntry) { entry in
            EnterPasswordSheet(entry: entry)
        }
        .searchable(text: $searchText, placement: .automatic, prompt: "Search cameras")
    }
}

/// Devices tab — add new cameras, view the synced list, remove entries.
struct DevicesPlaceholderView: View {
    @Environment(CameraStore.self) private var store
    @State private var showingAdd = false
    @State private var passwordEntryEntry: CameraEntry?
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if store.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No Cameras", systemImage: "video.slash")
                } description: {
                    Text("Cameras added here sync to your Mac, iPad, and other devices via iCloud. Passwords stay on this device.")
                } actions: {
                    Button("Add Camera…") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(store.orderedCameras(matching: searchText)) { entry in
                            HStack {
                                CameraRow(entry: entry)
                                Spacer()
                                if store.session(for: entry.id) == nil {
                                    Image(systemName: "key.slash")
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Missing password")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.remove(entry.id)
                                }
                                Button("Enter Password", systemImage: "key.fill") {
                                    passwordEntryEntry = entry
                                }
                                .tint(.accentColor)
                            }
                            .contextMenu {
                                Button("Enter Password", systemImage: "key.fill") {
                                    passwordEntryEntry = entry
                                }
                                Divider()
                                Button("Delete Camera", systemImage: "trash", role: .destructive) {
                                    store.remove(entry.id)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let displayed = store.orderedCameras(matching: searchText)
                            for index in offsets {
                                guard displayed.indices.contains(index) else { continue }
                                store.remove(displayed[index].id)
                            }
                        }
                    } header: {
                        Text("\(store.cameras.count) device\(store.cameras.count == 1 ? "" : "s") synced via iCloud")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Camera", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCameraView()
        }
        .sheet(item: $passwordEntryEntry) { entry in
            EnterPasswordSheet(entry: entry)
        }
        .searchable(text: $searchText, placement: .automatic, prompt: "Search cameras")
    }
}

/// Recordings tab. With no per-channel context, this shows a camera
/// picker; selecting one drills into `RecordingsView` for that
/// channel. Once a camera/channel is in focus elsewhere in the app
/// (Live grid → single channel view → Recordings tab inside there),
/// that flow is the more direct entry point.
struct RecordingsPlaceholderView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        if store.cameras.isEmpty {
            ContentUnavailableView(
                "No Cameras",
                systemImage: "clock.arrow.circlepath",
                description: Text("Add a camera to browse recordings. The camera list syncs from your Mac and other devices via iCloud.")
            )
        } else {
            List(store.orderedCameras()) { entry in
                if let session = store.session(for: entry.id) {
                    NavigationLink {
                        RecordingsCameraPicker(session: session)
                    } label: {
                        CameraListRow(entry: entry)
                    }
                } else {
                    HStack {
                        CameraListRow(entry: entry)
                        Spacer()
                        Image(systemName: "key.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Step between the Recordings tab's camera picker and the per-channel
/// recordings list. NVR/Hub devices expose many channels; single
/// cameras get auto-forwarded.
private struct RecordingsCameraPicker: View {
    let session: CameraSession

    var body: some View {
        Group {
            if session.channels.isEmpty {
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.channels.count == 1, let only = session.channels.first {
                RecordingsView(session: session, channel: only)
            } else {
                List(session.liveChannels, id: \.channel) { channel in
                    NavigationLink {
                        RecordingsView(session: session, channel: channel)
                    } label: {
                        Label(
                            channel.name ?? "Channel \(channel.channel + 1)",
                            systemImage: "video.fill"
                        )
                    }
                }
                .navigationTitle(session.entry.displayName)
            }
        }
        // Key the task off the session instance, not the camera UUID,
        // so Reconnect (which gives us a new session for the same
        // camera) actually re-fires the connect. AGENTS.md §8: avoid
        // stale shared state across instances.
        .task(id: ObjectIdentifier(session)) {
            await session.connect()
        }
    }
}

/// Settings tab is implemented in `SettingsView.swift`.
typealias SettingsPlaceholderView = SettingsView

private struct CameraListRow: View {
    let entry: CameraEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.headline)
                Text("\(entry.host):\(entry.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DevicePlaceholderView: View {
    let entry: CameraEntry
    @Environment(CameraStore.self) private var store
    @State private var showingPasswordSheet = false

    var body: some View {
        Group {
            if let session = store.session(for: entry.id) {
                CameraDetailView(session: session)
                    .toolbar {
                        ToolbarItem(placement: .secondaryAction) {
                            Button("Update Password", systemImage: "key.fill") {
                                showingPasswordSheet = true
                            }
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("No password on this device", systemImage: "key.slash")
                } description: {
                    Text("\(entry.displayName) was added on another device. Enter the password here to start streaming.")
                } actions: {
                    Button("Enter Password") { showingPasswordSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingPasswordSheet) {
            EnterPasswordSheet(entry: entry)
        }
    }
}

/// Compact row for camera lists across the app.
private struct CameraRow: View {
    let entry: CameraEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.headline)
                Text("\(entry.host):\(entry.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

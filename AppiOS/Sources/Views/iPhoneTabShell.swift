import SwiftUI
import AppShared

/// iPhone navigation paradigm: four tabs, each its own `NavigationStack`
/// so deep links into a tab don't get wiped when the user switches
/// elsewhere.
///
/// The Live tab takes a `NavigationPath` binding so an "Open Camera"
/// Shortcut/Siri intent can route directly to a camera's detail view
/// when the app launches in response to the intent. Other tabs keep
/// their default-managed stacks.
struct iPhoneTabShell: View {
    @Environment(CameraStore.self) private var store

    enum Tab: Hashable {
        case live
        case recordings
        case devices
        case settings
    }

    @State private var selectedTab: Tab = .live
    @State private var liveTabPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $liveTabPath) {
                LivePlaceholderView()
                    .navigationTitle("Live")
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
                    // Per-channel deep-link destination — pushed by
                    // expandable rows in the Live tab so an NVR's
                    // individual cameras are addressable directly.
                    // Falls back to `CameraDetailView` when the
                    // session is still mounting (no channels yet).
                    .navigationDestination(for: CameraChannelTarget.self) { target in
                        if let session = store.session(for: target.deviceID),
                           let channel = session.channels.first(where: { $0.channel == target.channel }) {
                            SingleChannelView(session: session, channel: channel)
                                // Belt-and-suspenders so swapping
                                // channels by tapping a sibling row
                                // rebuilds the live tile cleanly.
                                .id(target)
                        } else if let session = store.session(for: target.deviceID) {
                            // Session exists but channels haven't
                            // arrived yet (still connecting).
                            // Fall back to the device's full view.
                            CameraDetailView(session: session, focusedChannel: target.channel)
                        } else if let entry = store.cameras.first(where: { $0.id == target.deviceID }) {
                            ContentUnavailableView {
                                Label("No password on this device", systemImage: "key.slash")
                            } description: {
                                Text("\(entry.displayName) was added on another device. Enter the password to stream from it.")
                            }
                        } else {
                            ContentUnavailableView("Camera not found", systemImage: "video.slash")
                        }
                    }
            }
            .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            .tag(Tab.live)

            NavigationStack {
                RecordingsPlaceholderView()
                    .navigationTitle("Recordings")
            }
            .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
            .tag(Tab.recordings)

            NavigationStack {
                DevicesPlaceholderView()
                    .navigationTitle("Devices")
            }
            .tabItem { Label("Devices", systemImage: "video.fill") }
            .tag(Tab.devices)

            NavigationStack {
                SettingsPlaceholderView()
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
        .onChange(of: store.pendingIntentNavigation) { _, target in
            guard let target else { return }
            switch target {
            case .liveCamera(let deviceID):
                guard let entry = store.cameras.first(where: { $0.id == deviceID })
                else { break }
                // Switch to Live and push the camera detail. Reset the
                // path first so the user lands on the new camera at
                // depth 1, not stacked on whatever they were viewing.
                selectedTab = .live
                liveTabPath = NavigationPath()
                liveTabPath.append(entry)
            case .recording(let deviceID, _, _):
                guard let entry = store.cameras.first(where: { $0.id == deviceID })
                else { break }
                // Recording-aged tap → drill into the channel's
                // detail view. `applyPendingIntentFocus` has already
                // stashed the timestamp in `pendingRecordingScroll`;
                // the channel detail's `consumeRecordingScrollIfAny`
                // flips to the Recordings tab and auto-plays the
                // closest clip.
                selectedTab = .live
                liveTabPath = NavigationPath()
                liveTabPath.append(entry)
            }
            store.pendingIntentNavigation = nil
        }
    }
}

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
    /// 0.6.0 — set after the first appear's restoration logic has
    /// run so a re-render of the shell (which happens on every
    /// `store.cameras` change) doesn't keep re-pushing the same
    /// camera onto the path.
    @State private var restoredLastCamera: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $liveTabPath) {
                LivePlaceholderView()
                    .navigationTitle("Live")
                    .navigationDestination(for: CameraEntry.self) { entry in
                        Group {
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
                        // 0.6.0 — remember this as the last-viewed
                        // camera so a future cold launch lands here
                        // rather than the placeholder. Persisting on
                        // appear (not on push) catches both manual
                        // navigation and App-Intent deep links.
                        .onAppear { store.preferences.lastViewedCameraID = entry.id }
                    }
                    // Per-channel deep-link destination — pushed by
                    // expandable rows in the Live tab so an NVR's
                    // individual cameras are addressable directly.
                    // Falls back to `CameraDetailView` when the
                    // session is still mounting (no channels yet).
                    .navigationDestination(for: CameraChannelTarget.self) { target in
                        Group {
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
                        .onAppear { store.preferences.lastViewedCameraID = target.deviceID }
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
        .task {
            // 0.6.0 — restore the most-recently-viewed camera on
            // cold launch. App-Intent navigation (Open Camera Siri
            // shortcut, notification tap, recording tap) takes
            // precedence because its destination is more specific
            // than "wherever you were last". `restoredLastCamera`
            // gates this so a SwiftUI re-render doesn't keep
            // pushing the same entry onto the stack.
            guard !restoredLastCamera else { return }
            restoredLastCamera = true
            guard store.pendingIntentNavigation == nil,
                  let lastID = store.preferences.lastViewedCameraID,
                  let entry = store.cameras.first(where: { $0.id == lastID }) else { return }
            selectedTab = .live
            liveTabPath.append(entry)
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
            case .digest:
                // 0.5.0 Theme A5 — digest tap shows the
                // `DigestDetailView` sheet bound at the app
                // entry point (`ReolensiOSApp` watches
                // `store.pendingDigestDay`). Nothing to do here
                // — the sheet binding takes care of presentation
                // independently of the tab shell.
                break
            }
            store.pendingIntentNavigation = nil
        }
    }
}

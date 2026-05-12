import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Per-camera detail view: connects the session, then renders the
/// single-channel detail for a one-channel camera, or a multi-channel
/// grid for an NVR / Home Hub.
///
/// Mirrors the macOS `CameraDetailView` flow but trims the toolbar /
/// menu chrome that doesn't apply on iOS. Tab navigation (Live /
/// Recordings / Settings) is added by the wrapping `SingleCameraView`
/// when an individual channel is in focus — when we're showing the
/// grid, only Live is meaningful.
struct CameraDetailView: View {
    let session: CameraSession
    /// When set, jump straight into the per-channel detail for this
    /// channel ID instead of showing the multi-channel grid. Used by
    /// sidebar selection (`SidebarSection.device`) and by tapping a
    /// tile in the grid.
    var focusedChannel: Int? = nil

    @State private var didStart = false

    var body: some View {
        Group {
            if let focusedChannel,
               let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
                SingleChannelView(session: session, channel: channel)
            } else if session.channels.count > 1 {
                CameraGridView(session: session)
            } else if let channel = session.channels.first {
                SingleChannelView(session: session, channel: channel)
            } else {
                ContentUnavailableView("Connecting…", systemImage: "bolt.horizontal")
            }
        }
        .task(id: session.entry.id) {
            guard !didStart else { return }
            didStart = true
            await session.connect()
        }
        .navigationTitle(session.entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
///
/// Shows a "Try Again" affordance if the initial connection has been
/// stuck in `.connecting` for `connectionTimeoutSeconds`. URLSession
/// has a long default timeout (~60s) and Reolink hubs occasionally
/// stall during the initial login; without a manual retry button the
/// user had to force-quit the app.
struct CameraDetailView: View {
    let session: CameraSession
    /// When set, jump straight into the per-channel detail for this
    /// channel ID instead of showing the multi-channel grid. Used by
    /// sidebar selection (`SidebarSection.device`) and by tapping a
    /// tile in the grid.
    var focusedChannel: Int? = nil

    @State private var didStart = false
    @State private var slowConnect = false

    /// How long the session may sit in `.connecting` before the UI
    /// surfaces a retry option. ~25 seconds covers first-launch
    /// scenarios where iOS is still showing the Local Network
    /// permission dialog (which blocks the login HTTP request until
    /// the user taps Allow), and is comfortably short of URLSession's
    /// 60-second default.
    private static let connectionTimeoutSeconds: UInt64 = 25

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
                connectingPlaceholder
            }
        }
        .task(id: session.entry.id) {
            slowConnect = false
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.connectionTimeoutSeconds * 1_000_000_000)
                if !Task.isCancelled, session.status == .connecting {
                    slowConnect = true
                }
            }
            if !didStart {
                didStart = true
                await session.connect()
            }
            timeout.cancel()
        }
        .navigationTitle(session.entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var connectingPlaceholder: some View {
        if slowConnect || session.status.isError {
            ContentUnavailableView {
                Label(
                    session.status.isError ? "Couldn't reach the camera" : "Still connecting…",
                    systemImage: session.status.isError ? "exclamationmark.triangle" : "wifi.exclamationmark"
                )
            } description: {
                Text(retryDescription)
                    .multilineTextAlignment(.center)
            } actions: {
                Button {
                    Task {
                        slowConnect = false
                        await session.reconnect()
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Connecting…", systemImage: "bolt.horizontal")
            } description: {
                Text("Reaching \(session.entry.host).")
            }
        }
    }

    private var retryDescription: String {
        switch session.status {
        case .error(let msg):
            return "\(session.entry.host) returned an error: \(msg)"
        case .connecting:
            return "\(session.entry.host) hasn't responded yet. Check that the camera is on and on the same network."
        default:
            return "Reaching \(session.entry.host)."
        }
    }
}

private extension ConnectionStatus {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

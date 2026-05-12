import SwiftUI
import ReolinkAPI
import AppShared

/// Full-screen single-channel view. Three tabs mirror the macOS app's
/// per-channel detail: Live, Recordings, Settings. Phase 4 wired Live
/// + PTZ + Talkback; Phase 5 wires the Recordings tab; Settings comes
/// in a follow-up release.
struct SingleChannelView: View {
    let session: CameraSession
    let channel: ChannelStatus

    var body: some View {
        TabView {
            LiveTab(session: session, channel: channel)
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            RecordingsView(session: session, channel: channel)
                .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
        }
        .navigationTitle(channel.name ?? "Channel \(channel.channel + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Live" tab: the main-stream tile + PTZ controls + talkback button.
/// Pulled into its own struct so the parent TabView gets a clean child.
private struct LiveTab: View {
    let session: CameraSession
    let channel: ChannelStatus

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LiveTileView(
                    session: session,
                    channel: channel,
                    stream: .main
                )
                .aspectRatio(channel.isDualLens ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)

                PTZControlView(session: session, channelID: channel.channel)

                TalkbackButtonView(
                    session: session,
                    channelID: UInt8(channel.channel)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
    }
}

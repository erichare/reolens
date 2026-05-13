import SwiftUI
import AppShared
import ReolinkAPI

/// 0.5.0 — Host for a single-camera-in-its-own-window scene, used by
/// the macOS secondary `WindowGroup(for: ReolensScene.self)` and (on
/// iPad) the future Stage Manager multi-scene layout.
///
/// Resolves the `ReolensScene` enum to the corresponding live view —
/// `.camera(id:channel:)` shows the channel detail; `.main` reuses
/// `ContentView`; `.digest(day:)` (Theme A5) is reserved for a future
/// digest scene and currently bounces to `ContentView`. AGENTS.md §1
/// (platform parity): the same enum drives both macOS and iPadOS
/// scenes.
struct CameraSceneHost: View {
    let scene: ReolensScene
    @Environment(CameraStore.self) private var store

    var body: some View {
        switch scene {
        case .main:
            ContentView()
        case .camera(let id, let channel):
            if let camera = store.cameras.first(where: { $0.id == id }),
               let session = store.sessions[id],
               let ch = session.liveChannels.first(where: { $0.channel == channel })
                ?? session.channels.first(where: { $0.channel == channel }) {
                ChannelDetailContent(session: session, channel: ch)
                    .navigationTitle(channelLabel(camera: camera, channel: ch))
            } else {
                ContentUnavailableView(
                    "Camera not available",
                    systemImage: "video.slash",
                    description: Text("Reolens lost the session for this camera. Reopen it from the sidebar.")
                )
            }
        case .digest:
            ContentView()
        }
    }

    private func channelLabel(camera: CameraEntry, channel: ChannelStatus) -> String {
        let trimmed = (channel.name ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "\(camera.displayName) · Camera \(channel.channel + 1)"
        }
        return trimmed
    }
}

/// 0.5.0 — small wrapper around `@Environment(\.openWindow)` so the
/// sidebar context menus can stay agnostic about scene-routing. Lives
/// here next to the host so the value type and the opener move
/// together.
struct OpenInNewWindowButton: View {
    let scene: ReolensScene
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window", systemImage: "rectangle.badge.plus") {
            openWindow(value: scene)
        }
    }
}


import SwiftUI
import AVFoundation
import AVKit

/// Platform-bridge view that hosts an externally-owned `AVPlayer`.
/// Used by the shared `RecordingPlayerSheet` so playback chrome,
/// keyboard shortcuts, AirPlay routing, Picture-in-Picture, and
/// VoiceOver all come from the system AVKit views rather than a
/// hand-rolled wrapper. iOS uses `AVPlayerViewController`; macOS
/// uses `AVPlayerView` — both attach the engine's `player` and
/// react to identity changes (quality swap → new player).
public struct AVPlayerSurface: View {
    public let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public var body: some View {
        #if os(iOS) || os(visionOS)
        AVPlayerViewControllerRepresentable(player: player)
        #else
        AVPlayerViewRepresentable(player: player)
        #endif
    }
}

#if os(iOS) || os(visionOS)
private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        // Recordings don't use entry-from-PiP gestures yet, but
        // future deep-link support benefits from the OS knowing this
        // is a candidate.
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
    }
}
#else
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
#endif

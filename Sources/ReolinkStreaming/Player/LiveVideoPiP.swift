#if os(iOS) || os(visionOS)
import Foundation
import AVKit
import AVFoundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.reolens.streaming", category: "pip")

/// Wraps `AVPictureInPictureController` for our custom-decoded RTSP feed.
///
/// `AVPictureInPictureController` ships a content-source initializer for
/// `AVSampleBufferDisplayLayer` (iOS 15+), which is exactly the layer
/// `LiveVideoPlayer` already feeds. The delegate methods PiP requires
/// are mostly transport stubs since RTSP is a continuous live feed —
/// there's no seek, no end-time, and pause is a no-op (the camera keeps
/// pushing frames whether we render them or not).
///
/// Lifecycle:
/// 1. `init(player:)` constructs the controller and binds the player's
///    display layer as the content source.
/// 2. `start()` requests PiP. iOS animates into the floating window.
/// 3. `stop()` exits PiP. iOS animates back; the system may also dismiss
///    PiP without us asking (user tapped close, app entered background
///    with PiP unavailable, etc.) — the delegate fires either way.
///
/// macOS does not get PiP for now: AppKit's PiP path is AVPlayer-only,
/// and our pipeline is sample-buffer-based.
@MainActor
public final class LiveVideoPiP: NSObject {

    /// Whether PiP is currently active. KVO-able for SwiftUI state binding.
    @objc public dynamic private(set) var isActive: Bool = false

    /// Whether PiP is even possible (system support + layer attached to
    /// a window). Watch this to enable/disable the PiP toolbar button.
    @objc public dynamic private(set) var isPossible: Bool = false

    private let controller: AVPictureInPictureController
    private var observations: [NSKeyValueObservation] = []

    public init?(player: LiveVideoPlayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.info("PiP unsupported on this device")
            return nil
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: player.displayLayer,
            playbackDelegate: PlaybackDelegate.shared
        )
        self.controller = AVPictureInPictureController(contentSource: contentSource)
        super.init()
        self.controller.delegate = self
        self.observations.append(
            self.controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
                // Snapshot the bool here (not the controller) so we don't
                // hand a non-Sendable AVPictureInPictureController across
                // isolation boundaries under Swift 6 strict concurrency.
                let possible = ctrl.isPictureInPicturePossible
                Task { @MainActor [weak self] in
                    self?.isPossible = possible
                }
            }
        )
    }

    deinit {
        // KVO observations invalidate automatically when the controller
        // deinits, but be explicit since we hold strong refs.
        for obs in observations { obs.invalidate() }
    }

    /// Request entry into Picture-in-Picture. No-op if already active or
    /// the system says PiP isn't possible right now (e.g. screen recording
    /// is in progress).
    public func start() {
        guard !controller.isPictureInPictureActive else { return }
        guard controller.isPictureInPicturePossible else {
            log.info("PiP requested but not possible right now")
            return
        }
        // PiP requires a `playback`-compatible audio session category, even
        // for video-only feeds (iOS uses it as the signal that audio
        // continues backgrounded). Set defensively — if Talkback has the
        // session in `.playAndRecord`, leave it alone since that's already
        // compatible.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback && session.category != .playAndRecord {
            do {
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                log.error("PiP audio session setup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        controller.startPictureInPicture()
    }

    /// Exit Picture-in-Picture, returning the user to the inline view.
    public func stop() {
        guard controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension LiveVideoPiP: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isActive = true
            log.info("PiP started")
        }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isActive = false
            log.info("PiP stopped")
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
    }
}

/// PiP requires a playback delegate even for live, non-scrubbable feeds.
/// We provide a single shared instance that reports a never-paused,
/// infinite-duration live stream — RTSP from a Reolink camera doesn't
/// have a seek bar or a known end time.
///
/// All AppKit/UIKit delegate callbacks land on the main thread, so the
/// `nonisolated(unsafe)` shared instance is safe: every public method on
/// `PlaybackDelegate` runs main-actor-bound and the delegate holds no
/// mutable state of its own.
private final class PlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated(unsafe) static let shared = PlaybackDelegate()

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Live feed — there is no pause concept. Frames keep arriving from
        // the camera whether we render or not.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Indefinite live stream: start at .negativeInfinity so the scrub
        // bar reports "Live" and the user can't seek backward into a
        // buffer that doesn't exist.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Size hint from the system. We don't react — the
        // AVSampleBufferDisplayLayer handles its own aspect.
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // No-op: skipping a live feed is meaningless.
        completionHandler()
    }
}
#endif

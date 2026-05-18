import Foundation
import AVFoundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "playback.engine")

/// Orchestrates streaming, playback, and explicit export for a single
/// `PlayableRecording`. The shared `RecordingPlayerSheet` binds to
/// this object and renders its observable state; entry-point views
/// construct one per tap and discard it on dismiss.
///
/// The engine sits above `ChunkedResourceLoader` (streaming bytes
/// straight into AVPlayer) and `RecordingDownloader` (the full-file
/// path used by Export). Both are cache-aware: a previously-streamed
/// or previously-downloaded clip is served from disk on the second
/// tap.
@MainActor
@Observable
public final class RecordingPlaybackEngine {

    // MARK: - Observable state

    public enum Status: Equatable, Sendable {
        case idle
        /// First-frame bytes are being fetched. AVPlayer is wired up
        /// but `isReadyToPlay` is still false.
        case loading
        /// AVPlayer reports `.readyToPlay`. UI swaps the spinner for
        /// the video surface.
        case ready
        case failed(String)
    }

    public private(set) var status: Status = .idle
    /// Current quality variant being played. Mutating it triggers a
    /// soft swap (capture currentTime, swap player item, seek, resume).
    public private(set) var currentQuality: RecordingQuality = .low
    /// Underlying AVPlayer instance. Exposed read-only so the
    /// platform-specific view representable can attach it to an
    /// `AVPlayerLayer` / `AVPlayerView` / `AVPlayerViewController`.
    /// Replaced when the user switches quality.
    public private(set) var player: AVPlayer?
    /// Duration of the active asset, in seconds. Driven by an
    /// `AVPlayerItem` observation; 0 until the asset reports.
    public private(set) var duration: TimeInterval = 0
    /// Bytes received by the streaming loader. Useful for the
    /// "loading" panel before the first frame and for the export
    /// progress bar afterwards.
    public private(set) var bytesReceived: Int64 = 0
    /// Total bytes for the current variant. Populated once the
    /// streaming probe resolves or from the variant's hint.
    public private(set) var totalBytes: Int64 = 0
    /// True when the streaming loader has the full file on disk.
    /// Unlocks Export-from-cache paths.
    public private(set) var isFullyCached: Bool = false

    // MARK: - Inputs

    public let recording: PlayableRecording

    // MARK: - Private

    /// Active resource loader for the streaming path. Nil when the
    /// active variant is a `file://` URL (already-cached bookmark).
    private var loader: ChunkedResourceLoader?
    /// Time observer added to the player; removed on swap / teardown
    /// so we don't leak observation handlers.
    private var timeObserver: Any?
    /// AVPlayerItem KVO for status + duration.
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    /// Poll task that mirrors the loader's actor state into our
    /// observable properties. Cheap (timer-driven) and only runs
    /// while a streaming variant is active.
    private var loaderPollTask: Task<Void, Never>?

    public init(recording: PlayableRecording) {
        self.recording = recording
    }

    // MARK: - Lifecycle

    /// Start playback at the recording's `initialQuality`. Safe to
    /// call multiple times; subsequent calls re-load the active
    /// variant (useful for an explicit "Retry" button).
    public func start() {
        currentQuality = recording.initialQuality
        load(quality: currentQuality, resumingFrom: nil)
    }

    /// Tear down playback and cancel any in-flight downloads.
    public func stop() {
        teardown()
        status = .idle
        player = nil
    }

    /// Swap to the other quality if available. Captures the current
    /// playback time so the user resumes at the same instant — the
    /// "I want to see this in HD" gesture should never lose context.
    public func switchQuality(to quality: RecordingQuality) {
        guard quality != currentQuality,
              recording.variant(for: quality) != nil else { return }
        let resumeTime = player?.currentTime().seconds
        load(quality: quality, resumingFrom: resumeTime?.isFinite == true ? resumeTime : nil)
    }

    // MARK: - Internal: variant load

    private func load(quality: RecordingQuality, resumingFrom: TimeInterval?) {
        teardown()
        currentQuality = quality
        guard let variant = recording.variant(for: quality) else {
            status = .failed("No \(quality.label.lowercased())-quality variant available.")
            return
        }
        status = .loading
        bytesReceived = 0
        totalBytes = variant.expectedSize ?? 0
        isFullyCached = false

        // file:// path: bookmark replay or a previously-cached clip
        // (we point at it directly). No resource loader needed.
        if variant.url.isFileURL {
            let asset = AVURLAsset(url: variant.url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            observe(item: item, player: player, resumingFrom: resumingFrom)
            // Size hint for the export-progress UI even though we
            // don't need to download anything.
            if let size = (try? FileManager.default.attributesOfItem(atPath: variant.url.path)[.size] as? Int64), size > 0 {
                totalBytes = size
                bytesReceived = size
                isFullyCached = true
            }
            player.play()
            return
        }

        // Streaming path: pre-cached file in our recording cache?
        // Same behavior as file:// — skip the resource loader.
        if let cached = RecordingDownloader.cachedFile(for: variant.url) {
            let asset = AVURLAsset(url: cached)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            observe(item: item, player: player, resumingFrom: resumingFrom)
            if let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? Int64), size > 0 {
                totalBytes = size
                bytesReceived = size
                isFullyCached = true
            }
            player.play()
            return
        }

        // Streaming path: install the resource loader against a
        // `reolens-stream://` placeholder URL.
        let loader = ChunkedResourceLoader(upstreamURL: variant.url)
        self.loader = loader
        let asset = AVURLAsset(url: loader.placeholderURL)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observe(item: item, player: player, resumingFrom: resumingFrom)
        beginLoaderPolling()
        player.play()
    }

    /// Wire AVPlayer item observations so the engine's UI state
    /// stays in sync with the actual playback layer. Removed in
    /// `teardown` to avoid leaks.
    private func observe(item: AVPlayerItem, player: AVPlayer, resumingFrom: TimeInterval?) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    if case .loading = self.status { self.status = .ready }
                    if let t = resumingFrom, t > 0.5 {
                        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                          toleranceBefore: .positiveInfinity,
                                          toleranceAfter: .positiveInfinity)
                    }
                case .failed:
                    let msg = item.error?.localizedDescription ?? "Playback failed"
                    self.status = .failed(msg)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        durationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            let secs = CMTimeGetSeconds(item.duration)
            guard secs.isFinite, secs > 0 else { return }
            Task { @MainActor [weak self] in
                self?.duration = secs
            }
        }
    }

    private func beginLoaderPolling() {
        loaderPollTask?.cancel()
        loaderPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let loader = await self.loader else { return }
                let received = await loader.engine.bytesReceived
                let total = await loader.engine.totalBytes ?? 0
                let complete = await loader.engine.isComplete
                await MainActor.run {
                    if received > self.bytesReceived { self.bytesReceived = received }
                    if total > self.totalBytes { self.totalBytes = total }
                    if complete && !self.isFullyCached { self.isFullyCached = true }
                }
                if complete { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func teardown() {
        loaderPollTask?.cancel()
        loaderPollTask = nil
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        player?.pause()
        loader?.cancel()
        loader = nil
    }

    // MARK: - Export support

    /// Ensure the recording is fully downloaded at `quality`, then
    /// return the local file URL. Reuses a previously-completed
    /// stream (or a previously-completed `RecordingDownloader`
    /// fetch) when available. Errors propagate through Swift's
    /// throw mechanism so the export router can surface a single
    /// failure path.
    public func prepareFullDownload(quality: RecordingQuality) async throws -> URL {
        guard let variant = recording.variant(for: quality) else {
            throw EngineError.qualityUnavailable(quality)
        }
        if variant.url.isFileURL,
           FileManager.default.fileExists(atPath: variant.url.path) {
            return variant.url
        }
        if let cached = RecordingDownloader.cachedFile(for: variant.url) {
            return cached
        }
        // If the active variant is already streaming and complete,
        // honor that. (The engine's polling has already promoted to
        // cache in this case.)
        if quality == currentQuality, let loader,
           await loader.engine.isComplete,
           let completed = await loader.engine.completedFileURL {
            return completed
        }
        // Cold path: spin up a one-shot RecordingDownloader and
        // await completion. The downloader's parallel Range engine
        // is faster than the resource-loader path for full files
        // because the resource loader is keyed off AVPlayer's read
        // pattern, not raw throughput.
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, any Error>) in
            let downloader = RecordingDownloader()
            // The downloader is @MainActor; we're already on the
            // main actor here so direct access is fine.
            withObservationTracking {
                _ = downloader.state
                _ = downloader.localURL
            } onChange: {
                Task { @MainActor in
                    self.resumeIfReady(downloader: downloader, continuation: c)
                }
            }
            downloader.start(url: variant.url)
            // Resume synchronously if the download was a cache hit
            // and finished inside `start`.
            self.resumeIfReady(downloader: downloader, continuation: c)
        }
    }

    private func resumeIfReady(
        downloader: RecordingDownloader,
        continuation: CheckedContinuation<URL, any Error>
    ) {
        switch downloader.state {
        case .ready:
            if let url = downloader.localURL {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: EngineError.downloadProducedNoFile)
            }
        case .failed(let message):
            continuation.resume(throwing: EngineError.downloadFailed(message))
        case .idle, .downloading:
            return
        }
    }

    public enum EngineError: Error, LocalizedError, Sendable, Equatable {
        case qualityUnavailable(RecordingQuality)
        case downloadFailed(String)
        case downloadProducedNoFile

        public var errorDescription: String? {
            switch self {
            case .qualityUnavailable(let q):
                "The \(q.label.lowercased())-quality version of this recording isn't available."
            case .downloadFailed(let msg):
                msg
            case .downloadProducedNoFile:
                "The download finished without producing a file."
            }
        }
    }
}

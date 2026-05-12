import Foundation
import AVFoundation
import CoreImage
import Observation
import OSLog
@preconcurrency import CoreMedia
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.streaming", category: "player")

public enum LivePlayerState: Sendable, Equatable {
    case idle
    case connecting
    case playing
    case stopped
    case failed(String)
}

/// Orchestrates: RTSP client → H.264 or H.265 depacketizer → AVSampleBufferDisplayLayer.
///
/// Codec is detected from the SDP rtpmap field; the appropriate pipeline (H.264 vs
/// HEVC) is chosen automatically — the caller doesn't need to know in advance.
@MainActor
@Observable
public final class LiveVideoPlayer {

    public let displayLayer: AVSampleBufferDisplayLayer
    public private(set) var state: LivePlayerState = .idle
    /// Natural pixel size of the decoded video, observed from the first
    /// `CMSampleBuffer` we enqueue. `nil` until decoding starts. Useful for
    /// detecting dual-lens cameras (stitched frames at ~32:9 = 3.55).
    public private(set) var naturalSize: CGSize?

    /// Clockwise rotation in degrees applied by the host view.
    public var rotationDegrees: Int = 0

    /// The most recent decoded video frame (as a `CVPixelBuffer`), kept so
    /// the UI can snapshot the current live view to Photos / disk without
    /// stopping playback or running a parallel decode. Updated on every
    /// successful `enqueue` of a sample buffer.
    ///
    /// Not `@Observable`-tracked deliberately — we don't want SwiftUI to
    /// re-render every time a frame arrives. The snapshot UI reads the
    /// property imperatively at the moment the user taps the button.
    @ObservationIgnored
    public private(set) var latestPixelBuffer: CVPixelBuffer?

    /// Cached Core Image context for snapshot conversion. Created lazily
    /// on first use so apps that never snapshot don't pay the setup cost.
    @ObservationIgnored
    private lazy var snapshotContext: CIContext = CIContext(options: nil)

    /// Optional list of URLs to try in order. If the first fails with anything other than
    /// an authentication error, we try the next. Useful for "try main as H.265, fall back
    /// to H.264 if camera doesn't speak it" patterns.
    private let urls: [URL]
    private let username: String
    private let password: String
    private var client: RTSPClient?
    private var task: Task<Void, Never>?

    public convenience init(url: URL, username: String, password: String) {
        self.init(urls: [url], username: username, password: password)
    }

    public init(urls: [URL], username: String, password: String, rotationDegrees: Int = 0) {
        precondition(!urls.isEmpty, "at least one URL is required")
        self.urls = urls
        self.username = username
        self.password = password
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Disable implicit animations on bounds/position so resize-during-layout
        // doesn't fade the layer in/out (it would still render, but let's be
        // explicit so we can rule it out as a source of black flicker).
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "transform": NSNull()
        ]
        self.displayLayer = layer
        self.rotationDegrees = rotationDegrees
    }

    public func start() {
        guard task == nil else { return }
        state = .connecting
        let urls = self.urls
        let user = self.username
        let pass = self.password

        task = Task { [weak self] in
            await self?.runSession(urls: urls, username: user, password: pass)
        }
    }

    public func stop() {
        let t = task
        task = nil
        let c = client
        client = nil
        Task.detached {
            await c?.teardown()
            t?.cancel()
        }
        // Drop the cached snapshot buffer so a stopped player doesn't
        // hold a frame's worth of memory until the whole player object
        // is released (which may be later than expected if SwiftUI is
        // still mid-transition).
        latestPixelBuffer = nil
        state = .stopped
    }

    private func runSession(urls: [URL], username: String, password: String) async {
        var attempts: [String] = []
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { return }
            let pathLabel = url.path.isEmpty ? url.absoluteString : url.lastPathComponent
            do {
                try await playOne(url: url, username: username, password: password)
                return // ended normally
            } catch {
                attempts.append("\(pathLabel): \(error)")
                let isLast = index == urls.count - 1
                if isLast {
                    state = .failed("All streams failed:\n" + attempts.joined(separator: "\n"))
                } else {
                    if let c = client { await c.teardown() }
                    client = nil
                }
            }
        }
    }

    /// Run one URL's worth of session. Throws on failure so the caller can try a fallback.
    private func playOne(url: URL, username: String, password: String) async throws {
        enqueuedSampleCount = 0
        droppedSampleCount = 0
        didSetTimebase = false
        log.info("Attempting \(url.absoluteString, privacy: .public)")
        let client = RTSPClient(configuration: .init(url: url, username: username, password: password))
        self.client = client

        let sdp = try await client.connect()
        guard let video = sdp.firstVideoTrack else {
            throw NSError(domain: "Reolens.LivePlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let codec = video.rtpmap?.codec.uppercased() ?? ""
        let clockRate = Int32(video.rtpmap?.clockRate ?? 90_000)
        log.info("Codec=\(codec, privacy: .public) clockRate=\(clockRate)")

        try await client.setupVideo()
        let stream = try await client.play()
        state = .playing
        log.info("PLAY ok, awaiting frames")

        // Race the pipeline against a sustained "no new samples" watchdog. This
        // catches both the initial connect-but-no-frames case (e.g., bad codec
        // path, no IDR ever sent) AND the mid-stream stall case (server stops
        // transmitting after N seconds — common on Reolink Home Hub channels).
        // Throwing here causes runSession() to fall through to the next URL.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                switch codec {
                case "H264":
                    try await self.runH264Pipeline(video: video, clockRate: clockRate, stream: stream)
                case "H265", "HEVC":
                    try await self.runH265Pipeline(video: video, clockRate: clockRate, stream: stream)
                default:
                    throw NSError(
                        domain: "Reolens.LivePlayer", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported codec: \(codec.isEmpty ? "(none)" : codec)"]
                    )
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                var lastCount = -1
                var idleSeconds = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    let current = await self.enqueuedSampleCount
                    if current != lastCount {
                        idleSeconds = 0
                        lastCount = current
                    } else {
                        idleSeconds += 1
                    }
                    if idleSeconds >= Int(Self.stallTimeout) {
                        log.error("Stream watchdog: no new samples in \(idleSeconds)s (last count=\(lastCount))")
                        throw NSError(
                            domain: "Reolens.LivePlayer", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "stream stalled after \(idleSeconds)s of inactivity"]
                        )
                    }
                }
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
        if state == .playing { state = .stopped }
    }

    /// Maximum number of seconds without any new decoded sample before we
    /// consider the stream stalled and trigger URL fallback.
    private nonisolated static let stallTimeout: TimeInterval = 6


    private func runH264Pipeline(
        video: MediaDescription,
        clockRate: Int32,
        stream: AsyncStream<RTPChannelMessage>
    ) async throws {
        let sets = video.h264ParameterSets
        let assembler = H264SampleBufferAssembler(
            initialSPS: sets?.sps,
            initialPPS: sets?.pps,
            clockRate: clockRate
        )
        var depacketizer = H264Depacketizer()
        for await message in stream {
            if Task.isCancelled { break }
            guard case .rtp(_, let packet) = message else { continue }
            let nals = depacketizer.depacketize(packet.payload)
            for nal in nals {
                if let sample = try? assembler.ingest(nalType: nal.nalType, bytes: nal.bytes, rtpTimestamp: packet.timestamp) {
                    enqueue(sample)
                }
            }
        }
    }

    private func runH265Pipeline(
        video: MediaDescription,
        clockRate: Int32,
        stream: AsyncStream<RTPChannelMessage>
    ) async throws {
        let sets = video.h265ParameterSets
        log.info("H265 paramSets vps=\(sets?.vps.count ?? 0) sps=\(sets?.sps.count ?? 0) pps=\(sets?.pps.count ?? 0)")
        let assembler = H265SampleBufferAssembler(
            initialVPS: sets?.vps,
            initialSPS: sets?.sps,
            initialPPS: sets?.pps,
            clockRate: clockRate
        )
        var depacketizer = H265Depacketizer()
        var loggedFirstNAL = false
        var loggedFirstSample = false
        for await message in stream {
            if Task.isCancelled { break }
            guard case .rtp(_, let packet) = message else { continue }
            let nals = depacketizer.depacketize(packet.payload)
            for nal in nals {
                if !loggedFirstNAL {
                    loggedFirstNAL = true
                    log.info("First H265 NAL type=\(nal.nalType) bytes=\(nal.bytes.count) keyframe=\(nal.isKeyframe)")
                }
                if nal.isKeyframe {
                    log.info("H265 keyframe NAL type=\(nal.nalType)")
                }
                do {
                    if let sample = try assembler.ingest(nalType: nal.nalType, bytes: nal.bytes, rtpTimestamp: packet.timestamp) {
                        if !loggedFirstSample {
                            loggedFirstSample = true
                            log.info("First H265 sample buffer enqueued")
                        }
                        enqueue(sample)
                    }
                } catch {
                    log.error("H265 assembler error: \(error.localizedDescription, privacy: .public) nalType=\(nal.nalType)")
                }
            }
        }
    }

    private var didSetTimebase = false
    private var droppedSampleCount = 0
    private(set) var enqueuedSampleCount = 0

    private func enqueue(_ sample: CMSampleBuffer) {
        if !didSetTimebase {
            // Pin the layer's clock to the first sample's PTS so that the camera's
            // arbitrary RTP-timestamp-derived PTS values render in real time
            // instead of being queued for the distant future.
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            var timebase: CMTimebase?
            let status = CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            if status == noErr, let timebase {
                CMTimebaseSetTime(timebase, time: pts)
                CMTimebaseSetRate(timebase, rate: 1.0)
                displayLayer.controlTimebase = timebase
                log.info("Timebase pinned to first PTS \(pts.value)/\(pts.timescale)")
            } else {
                log.error("Timebase create failed status=\(status)")
            }
            didSetTimebase = true
        }

        if displayLayer.status == .failed {
            log.error("DisplayLayer failed before enqueue: \(self.displayLayer.error?.localizedDescription ?? "nil", privacy: .public). Flushing.")
            displayLayer.flush()
            didSetTimebase = false
        }
        guard displayLayer.isReadyForMoreMediaData else {
            droppedSampleCount += 1
            if droppedSampleCount == 1 || droppedSampleCount % 60 == 0 {
                log.error("DisplayLayer not ready; dropped \(self.droppedSampleCount) sample(s)")
            }
            return
        }
        displayLayer.enqueue(sample)
        enqueuedSampleCount += 1
        // Cache the latest pixel buffer for snapshot capture. Just a pointer
        // assignment; the buffer is already retained by the CMSampleBuffer
        // we just enqueued, so this costs nothing per-frame.
        if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
            latestPixelBuffer = imageBuffer
        }
        // Publish the decoded natural size once. Used by the UI to auto-mark
        // dual-lens cameras (which produce stitched ~32:9 frames).
        if naturalSize == nil, let fd = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            naturalSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            log.info("First decoded frame: \(dims.width)×\(dims.height)")
        }
        // Log first sample + every 60 thereafter so we can see continuous
        // forward progress in the log stream.
        if enqueuedSampleCount == 1 || enqueuedSampleCount % 60 == 0 {
            log.info("Enqueued \(self.enqueuedSampleCount) samples. status=\(self.displayLayer.status.rawValue) error=\(self.displayLayer.error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }

    // MARK: - Snapshot

    /// Capture the current live frame as a `CGImage`, applying the rotation
    /// that the host view is showing so the saved image matches what the
    /// user sees. Returns nil if no frame has been decoded yet (player is
    /// still connecting, camera is sleeping, etc.).
    ///
    /// Cheap: just runs the cached `CIContext` over the latest
    /// `CVPixelBuffer` — no decode, no extra RTSP traffic. Safe to call
    /// while playback continues.
    public func currentSnapshot() -> CGImage? {
        guard let pixelBuffer = latestPixelBuffer else { return nil }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        // Apply the same rotation the host view applies so saved frames
        // come out right-side-up. Clockwise degrees → CIImage rotation
        // counter-clockwise via the radians sign flip.
        if rotationDegrees != 0 {
            let radians = -CGFloat(rotationDegrees) * .pi / 180
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        }
        return snapshotContext.createCGImage(image, from: image.extent)
    }

    #if os(iOS) || os(visionOS)
    /// Convenience snapshot wrapper returning a `UIImage`. Caller is
    /// responsible for routing it to PhotoKit / share sheet / disk.
    public func currentSnapshotUIImage() -> UIImage? {
        guard let cg = currentSnapshot() else { return nil }
        return UIImage(cgImage: cg)
    }
    #elseif os(macOS)
    /// Convenience snapshot wrapper returning an `NSImage`.
    public func currentSnapshotNSImage() -> NSImage? {
        guard let cg = currentSnapshot() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    #endif
}

import SwiftUI
import AVFoundation
import OSLog
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "scrubber")

/// 0.5.0 Theme A3 — custom scrubber with a thumbnail rail for the
/// recordings player. Sits underneath the `AVPlayerView` / `AVPlayer`
/// host and replaces the native scrubber so we can show keyframe
/// previews above the cursor.
///
/// Cross-platform: the SwiftUI surface is identical on macOS and
/// iOS. The image type is platform-conditional (`NSImage` on macOS,
/// `UIImage` on iOS) but renders through `Image(nsImage:)` /
/// `Image(uiImage:)` accordingly.
///
/// Caching: thumbnails go through `ThumbnailCache.shared` keyed by
/// `(segmentID, offsetSeconds)`. The cache has a 500 MB LRU cap; a
/// long-running scrub session that walks across multiple segments
/// won't blow disk.
public struct ScrubberView: View {

    public let player: AVPlayer
    /// Stable identifier for this asset — typically the SearchFile's
    /// `name`. Used as the cache key for thumbnails.
    public let segmentID: String
    /// Duration of the underlying asset in seconds. We can't read
    /// this off the player synchronously, so callers load it once via
    /// `AVURLAsset(...).load(.duration)` and pass it in. A zero or
    /// negative value disables the scrubber rail.
    public let durationSeconds: TimeInterval
    /// One thumbnail per `thumbnailInterval` seconds. Default 5 s
    /// yields ~720 thumbnails per hour of footage.
    public let thumbnailInterval: TimeInterval

    public init(
        player: AVPlayer,
        segmentID: String,
        durationSeconds: TimeInterval,
        thumbnailInterval: TimeInterval = 5
    ) {
        self.player = player
        self.segmentID = segmentID
        self.durationSeconds = durationSeconds
        self.thumbnailInterval = thumbnailInterval
    }

    @State private var thumbnails: [Int: PlatformImage] = [:]
    @State private var currentSeconds: TimeInterval = 0
    @State private var isDragging = false
    @State private var dragPreviewSeconds: TimeInterval?
    @State private var generator: AVAssetImageGenerator?
    @State private var extractionTask: Task<Void, Never>?
    @State private var timeObserverToken: Any?

    public var body: some View {
        VStack(spacing: 6) {
            thumbnailRail
            scrubberBar
            timeRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .reolensGlassToolbar()
        .task(id: segmentID) {
            await prepare()
        }
        .onDisappear {
            extractionTask?.cancel()
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
                timeObserverToken = nil
            }
        }
    }

    private var thumbnailRail: some View {
        GeometryReader { proxy in
            let count = max(1, Int(durationSeconds / thumbnailInterval))
            let tileWidth = proxy.size.width / CGFloat(count)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    thumbnailTile(at: index, width: tileWidth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .leading) {
                if let preview = dragPreviewSeconds, durationSeconds > 0 {
                    let x = CGFloat(preview / durationSeconds) * proxy.size.width
                    PreviewBubble(seconds: preview)
                        .offset(x: max(0, min(x - 40, proxy.size.width - 80)), y: -28)
                }
            }
        }
        .frame(height: 48)
        .clipShape(.rect(cornerRadius: 6))
        // 0.6.2 a11y — VoiceOver announces total duration so users
        // know how long a clip runs without sighted scanning. The
        // rail itself isn't interactive; the scrubberBar carries
        // the adjustable trait below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thumbnail preview rail")
        .accessibilityValue("Total duration \(accessibleTimeLabel(durationSeconds))")
    }

    private func thumbnailTile(at index: Int, width: CGFloat) -> some View {
        Group {
            if let image = thumbnails[index] {
                #if canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #elseif canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
            }
        }
        .frame(width: width, height: 48)
        .clipped()
    }

    private var scrubberBar: some View {
        GeometryReader { proxy in
            let progress = durationSeconds > 0 ? currentSeconds / durationSeconds : 0
            let cursorX = max(0, min(CGFloat(progress) * proxy.size.width, proxy.size.width))
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3)).frame(height: 6)
                Capsule().fill(.tint).frame(width: cursorX, height: 6)
                Circle()
                    .fill(.tint)
                    .frame(width: 14, height: 14)
                    .position(x: cursorX, y: 7)
            }
            .contentShape(.rect)
            .gesture(scrubGesture(width: proxy.size.width))
        }
        .frame(height: 14)
        // 0.6.2 a11y — the scrubber thumb is the primary interaction.
        // VoiceOver announces current position + total duration; the
        // adjustable trait lets the user step via single-finger
        // swipe-up / swipe-down (iOS) or arrow keys (macOS Full
        // Keyboard Access) in 5-second increments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording position")
        .accessibilityValue("\(accessibleTimeLabel(currentSeconds)) of \(accessibleTimeLabel(durationSeconds))")
        .accessibilityAddTraits(.isAdjustable)
        .accessibilityAdjustableAction { direction in
            guard durationSeconds > 0 else { return }
            let step: TimeInterval = 5
            let target: TimeInterval
            switch direction {
            case .increment:
                target = min(durationSeconds, currentSeconds + step)
            case .decrement:
                target = max(0, currentSeconds - step)
            @unknown default:
                return
            }
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            currentSeconds = target
        }
    }

    /// VoiceOver-friendly time string. `formatTime` produces "1:23"
    /// (concise visual); this expands to "1 minute 23 seconds" so
    /// screen readers announce the position naturally.
    private func accessibleTimeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m == 0 {
            return "\(s) seconds"
        }
        if s == 0 {
            return "\(m) minute\(m == 1 ? "" : "s")"
        }
        return "\(m) minute\(m == 1 ? "" : "s") \(s) seconds"
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard durationSeconds > 0 else { return }
                isDragging = true
                let fraction = max(0, min(1, value.location.x / width))
                dragPreviewSeconds = fraction * durationSeconds
            }
            .onEnded { value in
                guard durationSeconds > 0 else { isDragging = false; return }
                let fraction = max(0, min(1, value.location.x / width))
                let target = fraction * durationSeconds
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                currentSeconds = target
                dragPreviewSeconds = nil
                isDragging = false
            }
    }

    private var timeRow: some View {
        HStack {
            Text(formatTime(currentSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatTime(durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Setup

    @MainActor
    private func prepare() async {
        // Observe current playback time for the cursor.
        if timeObserverToken == nil {
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                // `queue: .main` guarantees this callback already
                // runs on the MainActor's queue. Swift 6 strict
                // concurrency can't see that through `@Sendable`, so
                // assume the isolation explicitly to access the
                // MainActor-isolated `isDragging` / `currentSeconds`
                // without hopping through a separate Task.
                MainActor.assumeIsolated {
                    if !isDragging {
                        currentSeconds = CMTimeGetSeconds(time)
                    }
                }
            }
        }
        // Kick the background thumbnail extraction.
        extractionTask?.cancel()
        extractionTask = Task.detached(priority: .utility) {
            await Self.populateThumbnails(
                player: player,
                segmentID: segmentID,
                durationSeconds: durationSeconds,
                thumbnailInterval: thumbnailInterval,
                emit: { index, image in
                    Task { @MainActor in
                        thumbnails[index] = image
                    }
                }
            )
        }
    }

    private static func populateThumbnails(
        player: AVPlayer,
        segmentID: String,
        durationSeconds: TimeInterval,
        thumbnailInterval: TimeInterval,
        emit: @escaping @Sendable (Int, PlatformImage) -> Void
    ) async {
        guard durationSeconds > 0,
              let asset = player.currentItem?.asset as? AVURLAsset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 96, height: 54)

        let count = max(1, Int(durationSeconds / thumbnailInterval))
        for index in 0..<count {
            if Task.isCancelled { return }
            let seconds = Double(index) * thumbnailInterval
            // Cache hit first.
            if let data = await ThumbnailCache.shared.read(
                segmentID: segmentID,
                offsetSeconds: Int(seconds.rounded())
            ), let img = PlatformImage(data: data) {
                emit(index, img)
                continue
            }
            // Cache miss — extract.
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let cgImage = try await generator.image(at: time).image
                #if canImport(UIKit)
                let img = PlatformImage(cgImage: cgImage)
                if let jpeg = img.jpegData(quality: 0.7) {
                    await ThumbnailCache.shared.write(
                        segmentID: segmentID,
                        offsetSeconds: Int(seconds.rounded()),
                        jpegData: jpeg
                    )
                    emit(index, img)
                }
                #elseif canImport(AppKit)
                if let img = PlatformImage(cgImage: cgImage),
                   let jpeg = img.jpegData(quality: 0.7) {
                    await ThumbnailCache.shared.write(
                        segmentID: segmentID,
                        offsetSeconds: Int(seconds.rounded()),
                        jpegData: jpeg
                    )
                    emit(index, img)
                }
                #endif
            } catch {
                log.debug("Thumbnail extract failed at \(seconds)s: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct PreviewBubble: View {
    let seconds: TimeInterval
    var body: some View {
        Text(format(seconds))
            .font(.caption2.weight(.medium).monospacedDigit())
            .reolensGlassToast()
    }
    private func format(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Cross-platform image bridge

#if canImport(AppKit)
public typealias PlatformImage = NSImage
public extension NSImage {
    convenience init?(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    func jpegData(quality: CGFloat) -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
#elseif canImport(UIKit)
public typealias PlatformImage = UIImage
public extension UIImage {
    func jpegData(quality: CGFloat) -> Data? {
        self.jpegData(compressionQuality: quality)
    }
}
#endif


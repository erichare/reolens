import Foundation
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "clip-export")

/// Trim + export a recording into a fresh MP4 on disk. Used by the
/// bookmarks UI (Theme C1) to save / share a single clip.
///
/// The exporter is deliberately small: it composes a single
/// `AVMutableComposition` from one or more underlying MP4 segments
/// (cross-segment trims are supported), then runs an
/// `AVAssetExportSession` with the system "Highest" preset.
public enum ClipExporter {

    public struct Source: Sendable {
        public let url: URL
        /// Time range to take from this source, in seconds relative
        /// to the source's start.
        public let range: ClosedRange<TimeInterval>
        public init(url: URL, range: ClosedRange<TimeInterval>) {
            self.url = url
            self.range = range
        }
    }

    public struct ExportResult: Sendable {
        public let outputURL: URL
        public let durationSeconds: TimeInterval
    }

    public enum ExportError: Error, Sendable {
        case noSources
        case noVideoTrack(URL)
        case exportSessionUnavailable
        case exportFailed(String)
    }

    /// Compose `sources` head-to-tail into `outputURL`. Output is
    /// MP4 (`AVFileType.mp4`). Times outside a source's natural
    /// range are clamped.
    public static func export(
        sources: [Source],
        to outputURL: URL,
        preset: String = AVAssetExportPresetHighestQuality
    ) async throws -> ExportResult {
        guard !sources.isEmpty else { throw ExportError.noSources }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.exportSessionUnavailable
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var totalDuration: TimeInterval = 0
        for source in sources {
            let asset = AVURLAsset(url: source.url)
            let assetDuration = try await asset.load(.duration)
            let assetMaxSeconds = CMTimeGetSeconds(assetDuration)
            let lo = max(0, source.range.lowerBound)
            let hi = min(assetMaxSeconds, source.range.upperBound)
            guard hi > lo else { continue }
            let start = CMTime(seconds: lo, preferredTimescale: 600)
            let duration = CMTime(seconds: hi - lo, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)

            let assetVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let assetVideoTrack = assetVideoTracks.first else {
                throw ExportError.noVideoTrack(source.url)
            }
            try videoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: cursor)
            if let audioTrack {
                let assetAudioTracks = try await asset.loadTracks(withMediaType: .audio)
                if let assetAudioTrack = assetAudioTracks.first {
                    try audioTrack.insertTimeRange(timeRange, of: assetAudioTrack, at: cursor)
                }
            }
            cursor = CMTimeAdd(cursor, duration)
            totalDuration += hi - lo
        }

        // Remove a stale output file at the target path (the
        // exporter refuses to overwrite).
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.exportSessionUnavailable
        }
        exporter.shouldOptimizeForNetworkUse = true

        // 0.5.1 — migrated from the deprecated callback-based
        // `export()` + `status` / `error` polling to the iOS 18 /
        // macOS 15 `export(to:as:)` async-throws API. Failure now
        // surfaces as a thrown Error rather than a sentinel state
        // we have to read after the fact. Same on-disk result;
        // cleaner control flow.
        do {
            try await exporter.export(to: outputURL, as: .mp4)
            return ExportResult(outputURL: outputURL, durationSeconds: totalDuration)
        } catch let error as CancellationError {
            throw ExportError.exportFailed("cancelled (\(error))")
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }
}

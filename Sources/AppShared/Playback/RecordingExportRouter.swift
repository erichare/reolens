import Foundation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.app", category: "playback.export")

/// Cross-platform export dispatch for a `PlayableRecording`. The
/// router prepares a staged MP4 (downloading + trimming as needed)
/// and hands it back to the caller, which performs the platform-
/// specific presentation (`.fileExporter`, `ShareLink`, Photos auth
/// + save). Splitting it this way keeps AppShared free of UIKit /
/// AppKit imports — the staging step is the same regardless of
/// destination, only the final handoff differs.
public enum RecordingExportRouter {

    /// Prepare a staged MP4 ready for handoff. The returned URL
    /// points at a file in the recordings or staging cache —
    /// callers should consume it promptly (the staging directory
    /// gets pruned on its own schedule).
    ///
    /// Steps:
    ///   1. Ensure the full file for `quality` is on disk by calling
    ///      `engine.prepareFullDownload(quality:)`. This is a cache
    ///      hit when streaming has already completed for that
    ///      variant — otherwise it spawns a parallel-Range download.
    ///   2. If `trim` is nil, return the cached file directly.
    ///   3. If `trim` is non-nil, stage a trimmed MP4 via
    ///      `ClipExportCoordinator.stage(_:)`.
    public static func prepareStagedFile(
        recording: PlayableRecording,
        quality: RecordingQuality,
        trim: ClosedRange<TimeInterval>?,
        engine: RecordingPlaybackEngine
    ) async throws -> URL {
        let fullURL = try await engine.prepareFullDownload(quality: quality)
        guard let trim else { return fullURL }
        let baseName = suggestedBasename(for: recording, quality: quality, trimmed: true)
        let request = ClipExportRequest(
            sources: [.init(url: fullURL, range: trim)],
            suggestedFilename: baseName
        )
        let staged = try await ClipExportCoordinator.stage(request)
        return staged.stagedURL
    }

    /// Filesystem-safe basename for the exported clip. Used by
    /// `.fileExporter`'s `defaultFilename` parameter and by
    /// `ShareLink`'s `suggestedFileName`.
    public static func suggestedBasename(
        for recording: PlayableRecording,
        quality: RecordingQuality,
        trimmed: Bool
    ) -> String {
        let start = recording.startDate ?? Date()
        let raw = ClipExportCoordinator.suggestedFilename(
            cameraName: recording.cameraName,
            start: start
        )
        let qualityTag = quality == .high ? "HD" : "SD"
        return trimmed ? "\(raw)_\(qualityTag)_clip" : "\(raw)_\(qualityTag)"
    }

    /// Suggested filename including extension. Used by
    /// `.fileExporter` document factories that expect a name with
    /// suffix.
    public static func suggestedFilename(
        for recording: PlayableRecording,
        quality: RecordingQuality,
        trimmed: Bool
    ) -> String {
        suggestedBasename(for: recording, quality: quality, trimmed: trimmed) + ".mp4"
    }
}

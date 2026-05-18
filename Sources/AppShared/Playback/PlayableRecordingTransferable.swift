import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "playback.transferable")

/// Lazy `Transferable` wrapper for a `PlayableRecording`. Lets a
/// `ShareLink` in the player sheet's Export menu render with no
/// preparation cost — the system invokes the file representation
/// only after the user picks a destination, at which point we run
/// the full download (or hit the cache) and stage a trimmed MP4 if
/// the recording carries an `initialTrim`.
///
/// Pairs with `BookmarkClipTransferable` (bookmarks-only path) but
/// is independent so the player sheet can share any recording —
/// not just the ones a user has bookmarked.
public struct PlayableRecordingTransferable: Sendable {
    public let recording: PlayableRecording
    public let quality: RecordingQuality
    public let trim: ClosedRange<TimeInterval>?
    public let suggestedFilename: String

    public init(
        recording: PlayableRecording,
        quality: RecordingQuality,
        trim: ClosedRange<TimeInterval>?
    ) {
        self.recording = recording
        self.quality = quality
        self.trim = trim
        self.suggestedFilename = RecordingExportRouter.suggestedBasename(
            for: recording,
            quality: quality,
            trimmed: trim != nil
        )
    }
}

extension PlayableRecordingTransferable: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { item in
            let url = try await prepare(item: item)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.suggestedFilename + ".mp4" }
    }

    /// Resolve a playable URL for the chosen variant + quality,
    /// reusing the recording cache so a previously-streamed or
    /// previously-downloaded clip is a zero-fetch hit. Throws if
    /// the variant doesn't exist on the recording.
    private static func prepare(item: PlayableRecordingTransferable) async throws -> URL {
        guard let variant = item.recording.variant(for: item.quality) else {
            throw URLError(.fileDoesNotExist)
        }

        // file:// — already on disk (bookmark replay).
        if variant.url.isFileURL,
           FileManager.default.fileExists(atPath: variant.url.path) {
            return try await applyTrimIfNeeded(sourceURL: variant.url, item: item)
        }

        // Recording cache hit.
        if let cached = RecordingDownloader.cachedFile(for: variant.url) {
            return try await applyTrimIfNeeded(sourceURL: cached, item: item)
        }

        // Cold path: spin up a fresh downloader and await completion.
        let url = try await fullDownload(from: variant.url)
        return try await applyTrimIfNeeded(sourceURL: url, item: item)
    }

    private static func applyTrimIfNeeded(
        sourceURL: URL,
        item: PlayableRecordingTransferable
    ) async throws -> URL {
        guard let trim = item.trim else { return sourceURL }
        let request = ClipExportRequest(
            sources: [.init(url: sourceURL, range: trim)],
            suggestedFilename: item.suggestedFilename
        )
        let staged = try await ClipExportCoordinator.stage(request)
        return staged.stagedURL
    }

    /// Spawn an isolated `RecordingDownloader` and await `.ready`.
    /// The downloader's observable state isn't easily bridged into a
    /// non-actor context, so we poll via a small AsyncStream that
    /// MainActor-checks the state. This is fine: the share path is
    /// rare and the polling cadence is mild.
    @MainActor
    private static func fullDownload(from url: URL) async throws -> URL {
        let downloader = RecordingDownloader()
        downloader.start(url: url)
        // The downloader's `state` is observable but we need a
        // promise-style await here. Use a continuation seeded by a
        // KVO-style observation via SwiftUI's withObservationTracking.
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, any Error>) in
            // Take an initial snapshot in case start() resolved
            // synchronously off a cache hit.
            if let url = readyURL(from: downloader) {
                c.resume(returning: url)
                return
            }
            if case .failed(let message) = downloader.state {
                c.resume(throwing: URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
            // Loop the observation by re-registering inside the
            // change handler — Swift's withObservationTracking only
            // fires once per registration.
            poll(downloader: downloader, continuation: c)
        }
    }

    @MainActor
    private static func poll(
        downloader: RecordingDownloader,
        continuation: CheckedContinuation<URL, any Error>
    ) {
        withObservationTracking {
            _ = downloader.state
            _ = downloader.localURL
        } onChange: {
            Task { @MainActor in
                if let url = readyURL(from: downloader) {
                    continuation.resume(returning: url)
                } else if case .failed(let message) = downloader.state {
                    continuation.resume(throwing: URLError(
                        .unknown,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                } else {
                    poll(downloader: downloader, continuation: continuation)
                }
            }
        }
    }

    @MainActor
    private static func readyURL(from downloader: RecordingDownloader) -> URL? {
        if case .ready = downloader.state, let url = downloader.localURL { return url }
        return nil
    }
}

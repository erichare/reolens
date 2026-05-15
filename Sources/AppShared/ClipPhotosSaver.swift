import Foundation
import OSLog

#if os(iOS) || os(visionOS)
import Photos
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "clip-photos-saver")

/// 0.6.2 — iOS / iPadOS "Save to Photos" route for the unified clip
/// export storyline. Mirrors `SnapshotSaver`'s shape (add-only Photos
/// auth + a `PHAssetCreationRequest`), but consumes a staged MP4
/// `videoFileURL` produced by `ClipExportCoordinator.stage(_:)` rather
/// than a raw `CGImage`.
///
/// macOS has no native "save to camera roll" surface — the
/// `BookmarksSheet` menu hides the Photos destination on that platform,
/// and this enum's macOS branch returns `.unsupported` so any
/// accidental call surfaces as a no-op with diagnostics.
public enum ClipPhotosSaver {

    public enum Result: Sendable, Equatable {
        case saved
        case denied
        case unsupported
        case noFile
        case failed(String)
    }

    /// Save the staged MP4 at `videoFileURL` to the Photos library.
    /// Caller is expected to have already produced the file via
    /// `ClipExportCoordinator.stage(_:)`.
    public static func save(videoFileURL: URL) async -> Result {
        guard FileManager.default.fileExists(atPath: videoFileURL.path) else {
            return .noFile
        }
        #if os(iOS) || os(visionOS)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            log.info("Photos access denied")
            return .denied
        case .notDetermined:
            // The above call resolves .notDetermined, so this branch is
            // defensive — treat as denied if we somehow land here.
            return .denied
        @unknown default:
            return .denied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // The staged file is in caches; let Photos copy it
                // rather than move, because the coordinator's prune
                // sweep will reclaim the cache entry on its own
                // schedule and we don't want a race where Photos
                // hasn't finished ingesting before the file vanishes.
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: videoFileURL, options: options)
            }
            log.info("Saved clip \(videoFileURL.lastPathComponent, privacy: .private) to Photos")
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        log.info("Photos save unsupported on this platform; staged file remained at \(videoFileURL.path, privacy: .public)")
        return .unsupported
        #endif
    }
}

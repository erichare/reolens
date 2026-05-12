import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// Owns the on-disk preview-snapshot cache for each (cameraID, channel)
/// pair. Added in 0.4.0 alongside the static-preview-by-default grid
/// mode (Settings → General → "Live previews in grid").
///
/// Cache layout (under `~/Library/Caches/Reolens/previews/`):
///
///     {cameraId-uuid}-ch{n}.jpg
///
/// Caches are intentionally NOT synced via iCloud — they're regenerable
/// artifacts, not metadata (AGENTS.md §7 schema is untouched). The
/// system may purge them under storage pressure; that's fine — the
/// grid will refetch on next render.
///
/// All writes go through this actor so concurrent refresh calls don't
/// race on the same file. Reads use `try Data(contentsOf:)` directly
/// because they need to be synchronous in SwiftUI view bodies; reading
/// a file mid-write yields either old or new bytes, never garbage,
/// because we write to a temp file and atomically replace.
public actor CameraPreviewService {
    public static let shared = CameraPreviewService()

    private let log = Logger(subsystem: "com.reolens.Reolens", category: "PreviewCache")
    private let session: URLSession
    private let directory: URL

    /// Refresh tasks in flight, keyed by cache filename, so two callers
    /// asking for the same preview only trigger one HTTP fetch.
    private var inflight: [String: Task<Data?, Never>] = [:]

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = caches
            .appendingPathComponent("Reolens", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Synchronous read of the cached preview, if present. Safe to call
    /// from a SwiftUI view body via a small wrapper that schedules an
    /// `await` for the live data.
    nonisolated public func cachedData(cameraID: UUID, channel: Int) -> Data? {
        let url = Self.fileURL(in: Self.cachesPreviewDirectory, cameraID: cameraID, channel: channel)
        return try? Data(contentsOf: url)
    }

    /// File modification time, used to show "↻ updated <ago>" overlays
    /// on tiles. Nil if there's no cached preview yet.
    nonisolated public func cachedAt(cameraID: UUID, channel: Int) -> Date? {
        let url = Self.fileURL(in: Self.cachesPreviewDirectory, cameraID: cameraID, channel: channel)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[FileAttributeKey.modificationDate] as? Date else { return nil }
        return mod
    }

    /// Download a fresh JPEG from the camera's `cmd=Snap` endpoint and
    /// store it in the cache. Returns the new bytes, or nil on any
    /// failure (network error, non-200 response, write error). Multiple
    /// concurrent calls for the same (cameraID, channel) deduplicate to
    /// a single HTTP request.
    @discardableResult
    public func refresh(snapshotURL: URL, cameraID: UUID, channel: Int) async -> Data? {
        let key = Self.fileName(cameraID: cameraID, channel: channel)
        if let existing = inflight[key] {
            return await existing.value
        }
        let task = Task<Data?, Never> { [self, log] in
            do {
                let (data, response) = try await session.data(from: snapshotURL)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    // AGENTS.md §11 — don't log the URL (contains credentials
                    // as fallback when no token is available). Status only.
                    log.warning("Snap returned HTTP \(http.statusCode, privacy: .public); preview not updated")
                    return nil
                }
                try await write(data: data, cameraID: cameraID, channel: channel)
                return data
            } catch {
                log.warning("Preview refresh failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return await task.value
    }

    /// Overwrite the preview cache with bytes captured from a live
    /// decoded frame (e.g. when the user opens a single-channel detail
    /// view, the first keyframe doubles as the freshest possible
    /// preview). Skips the network entirely.
    public func storeFromLive(data: Data, cameraID: UUID, channel: Int) async {
        do {
            try await write(data: data, cameraID: cameraID, channel: channel)
        } catch {
            log.warning("Live-frame preview write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Encode a `CGImage` to JPEG and store it as the preview for this
    /// (cameraID, channel). Called from the live-tile views the moment
    /// the player emits its first decoded frame so the next grid render
    /// in preview mode reflects what the camera is showing *right now*.
    public func storeFromLive(cgImage: CGImage, cameraID: UUID, channel: Int) async {
        guard let data = Self.jpegData(from: cgImage, quality: 0.85) else { return }
        await storeFromLive(data: data, cameraID: cameraID, channel: channel)
    }

    /// JPEG-encode a `CGImage` with ImageIO. Quality is 0.85 — visibly
    /// indistinguishable from the source on a grid tile and ~3× smaller
    /// on disk than the source PNG would be.
    private static func jpegData(from cgImage: CGImage, quality: Double) -> Data? {
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    /// Atomic write to the cache directory: write to a tempfile in the
    /// same directory, then `replaceItemAt` to move it onto the target.
    /// Keeps concurrent readers from seeing a half-written file.
    private func write(data: Data, cameraID: UUID, channel: Int) async throws {
        let target = Self.fileURL(in: directory, cameraID: cameraID, channel: channel)
        let temp = directory.appendingPathComponent("." + Self.fileName(cameraID: cameraID, channel: channel) + ".tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: target)
        }
    }

    /// Delete the preview when a camera is removed. Called from
    /// `CameraStore.remove(...)` for tidiness; the OS would purge them
    /// anyway under storage pressure, but explicit cleanup keeps
    /// switched-account scenarios predictable.
    public func purge(cameraID: UUID) async {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let prefix = cameraID.uuidString + "-ch"
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func fileName(cameraID: UUID, channel: Int) -> String {
        "\(cameraID.uuidString)-ch\(channel).jpg"
    }

    private static func fileURL(in directory: URL, cameraID: UUID, channel: Int) -> URL {
        directory.appendingPathComponent(fileName(cameraID: cameraID, channel: channel))
    }

    /// Stand-alone directory accessor for the synchronous nonisolated
    /// reads. Computed identically to the instance `directory` —
    /// duplicated so it doesn't have to touch actor state.
    private static let cachesPreviewDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches
            .appendingPathComponent("Reolens", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// UserDefaults key controlling whether the camera grid uses live RTSP
/// previews (current 0.3.0 behavior, opt-in in 0.4.0) or static cached
/// snapshots (new 0.4.0 default). Read by `LiveCameraTile` and
/// `LiveTileView` at render time so flipping the Settings toggle takes
/// effect on the next layout pass.
public enum GridPreviewSetting {
    public static let liveGridDefaultsKey = "com.reolens.liveGridPreviews"

    public static var liveGridEnabled: Bool {
        UserDefaults.standard.bool(forKey: liveGridDefaultsKey)
    }
}

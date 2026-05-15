import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "clip-export-coordinator")

/// 0.6.2 — unified export-destination surface for `ClipExporter`.
///
/// 0.5.0 / 0.5.1 / 0.6.0 shipped `ClipExporter` itself (the file-side
/// composition + trim) and the macOS `NSSavePanel` route. The other
/// destinations users expect — Save to Photos, share-sheet, macOS
/// Finder drag-out — lived as TODO comments. 0.6.2 collapses those
/// into a single coordinator the UI layer drives:
///
/// 1. Caller builds a `ClipExportRequest` (sources + suggested name).
/// 2. Coordinator stages the exported MP4 into a managed cache
///    subdirectory, returning a `StagedExport` ticket.
/// 3. Caller hands the ticket's `stagedURL` to the platform-specific
///    destination handler (`PHPhotoLibrary` on iOS, `NSSharingService
///    Picker` on macOS, `.onDrag` for Finder drag-out, etc.).
///
/// The coordinator only handles the file-side work — destination
/// presentation lives in the platform shells. Splitting it this way
/// keeps AppShared free of `UIKit` / `AppKit` imports and keeps the
/// staging logic unit-testable without AVFoundation in the test target.
public enum ClipExportDestination: String, Sendable, CaseIterable {
    /// iOS / iPadOS only: add the exported file to the user's Photos
    /// library. Requires `NSPhotoLibraryAddUsageDescription` and
    /// `PHAuthorizationStatus.authorized` (or `.limited`).
    case photos
    /// Both platforms: hand the staged URL to the system share-sheet
    /// (`UIActivityViewController` on iOS, `NSSharingServicePicker` on
    /// macOS).
    case shareSheet
    /// macOS: hand the staged URL to a SwiftUI `.onDrag` modifier so
    /// the user can drop the clip into Finder / another app.
    case dragOut
    /// macOS: stage the file, then move it to a user-chosen
    /// destination obtained from `NSSavePanel`. Preserves the 0.5.0
    /// Save-As… flow.
    case savePanel
}

/// What the caller asks the coordinator to do.
///
/// `sources` flows through to `ClipExporter.export` unchanged.
/// `suggestedFilename` is the basename (without extension) the staged
/// file will use; the coordinator appends `.mp4`. Pass nil to let the
/// coordinator generate one from the current timestamp.
public struct ClipExportRequest: Sendable {
    public let sources: [ClipExporter.Source]
    public let suggestedFilename: String?

    public init(sources: [ClipExporter.Source], suggestedFilename: String? = nil) {
        self.sources = sources
        self.suggestedFilename = suggestedFilename
    }
}

/// Output ticket from the coordinator. UI handlers consume `stagedURL`.
public struct StagedExport: Sendable, Equatable {
    public let stagedURL: URL
    public let durationSeconds: TimeInterval

    public init(stagedURL: URL, durationSeconds: TimeInterval) {
        self.stagedURL = stagedURL
        self.durationSeconds = durationSeconds
    }
}

public enum ClipExportCoordinatorError: Error, Sendable, Equatable {
    case stagingDirectoryUnavailable
    case exporterFailed(String)
}

public enum ClipExportCoordinator {

    // MARK: - Filename builder

    /// Compose a filesystem-safe basename from a camera name + start
    /// instant. Used by the bookmark-export path so the file the user
    /// drops into Finder / sees in Photos carries a recognizable name
    /// rather than a UUID. Pure (no I/O) so unit tests can lock down
    /// the exact format.
    ///
    /// Examples:
    /// - ("Driveway", 2026-05-15T19:32:44Z) → "Driveway_2026-05-15_19-32-44"
    /// - ("Front Door / Camera", …) → "Front_Door_Camera_…"
    public static func suggestedFilename(
        cameraName: String,
        start: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    ) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: start
        )
        let datePart = String(
            format: "%04d-%02d-%02d_%02d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0
        )
        let namePart = sanitize(cameraName)
        // Empty / all-disallowed name collapses to "Clip" rather than
        // producing a leading underscore.
        return namePart.isEmpty ? "Clip_\(datePart)" : "\(namePart)_\(datePart)"
    }

    /// Lowercase the per-character allowlist into a private helper so
    /// the suggested-filename + assertion logic share the rule. The
    /// rule itself: ASCII alphanumerics + dash. Spaces / slashes /
    /// punctuation collapse to underscores; runs of underscores
    /// flatten.
    private static func sanitize(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let isAlpha = (0x30...0x39).contains(value)         // 0–9
                || (0x41...0x5A).contains(value)                // A–Z
                || (0x61...0x7A).contains(value)                // a–z
                || value == 0x2D                                 // -
            return isAlpha ? Character(scalar) : "_"
        }
        var collapsed = ""
        var lastWasUnderscore = false
        for ch in mapped {
            if ch == "_" {
                if !lastWasUnderscore { collapsed.append(ch) }
                lastWasUnderscore = true
            } else {
                collapsed.append(ch)
                lastWasUnderscore = false
            }
        }
        // Strip leading / trailing underscores so the basename reads
        // cleanly in Finder / Photos.
        while collapsed.hasPrefix("_") { collapsed.removeFirst() }
        while collapsed.hasSuffix("_") { collapsed.removeLast() }
        return collapsed
    }

    // MARK: - Staging directory

    /// The on-disk location staged exports land in. A subdirectory of
    /// the caches directory so the OS is free to evict the contents
    /// under memory pressure — staged files are intermediate; the
    /// destination handler is expected to read them promptly and move
    /// / copy / hand off to a system service.
    public static var stagingDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Reolens", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
    }

    /// Materialize the staging directory if it doesn't exist. Returns
    /// the directory URL or throws if the filesystem refuses.
    @discardableResult
    public static func ensureStagingDirectory() throws -> URL {
        let dir = stagingDirectory
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            return dir
        } catch {
            log.error("Could not create staging directory at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ClipExportCoordinatorError.stagingDirectoryUnavailable
        }
    }

    /// Build the target URL the coordinator will write to for a given
    /// request. The basename comes from `request.suggestedFilename`
    /// (sanitized — callers can pass already-built `suggestedFilename`
    /// output) or falls back to a timestamp-based name.
    public static func stagedURL(
        for request: ClipExportRequest,
        now: Date = Date()
    ) throws -> URL {
        let dir = try ensureStagingDirectory()
        let base = request.suggestedFilename.map(sanitize) ?? ""
        let cleaned = base.isEmpty
            ? suggestedFilename(cameraName: "Clip", start: now)
            : base
        return dir.appendingPathComponent(cleaned).appendingPathExtension("mp4")
    }

    // MARK: - Staging entry point

    /// Stage `request.sources` into a fresh MP4 inside the staging
    /// directory. UI calls this on the main actor, awaits, then routes
    /// the resulting `StagedExport` to the destination handler.
    ///
    /// Errors surface as `ClipExportCoordinatorError.exporterFailed`
    /// so the BookmarksSheet status row can render one consistent
    /// shape regardless of which downstream layer failed.
    public static func stage(_ request: ClipExportRequest) async throws -> StagedExport {
        let output = try stagedURL(for: request)
        do {
            let result = try await ClipExporter.export(sources: request.sources, to: output)
            return StagedExport(
                stagedURL: result.outputURL,
                durationSeconds: result.durationSeconds
            )
        } catch let error as ClipExporter.ExportError {
            throw ClipExportCoordinatorError.exporterFailed(String(describing: error))
        } catch {
            throw ClipExportCoordinatorError.exporterFailed(error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    /// Prune staged files older than `olderThan` seconds. Called on
    /// app launch + after each successful destination handoff so the
    /// staging directory doesn't accumulate. The default cutoff is one
    /// hour — long enough for a slow share-sheet user to finish
    /// picking a destination, short enough that the cache doesn't grow.
    @discardableResult
    public static func pruneStaging(olderThan seconds: TimeInterval = 3600) -> Int {
        let dir = stagingDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        // safe: best-effort prune. Unreadable directory → skip and let
        // the next sweep retry; we never block staging on cleanup.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let cutoff = Date().addingTimeInterval(-seconds)
        var removed = 0
        for entry in entries {
            // safe: missing mtime → treat as ancient (.distantPast falls
            // through the cutoff check below).
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch {
                log.warning("Could not prune staged export \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }
}

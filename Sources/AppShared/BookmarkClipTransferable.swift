import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import ReolinkAPI

/// 0.6.2 — `Transferable` wrapper that lets a `ShareLink` lazily
/// produce a trimmed clip MP4. The share-sheet flow goes:
///
/// 1. User taps Share in the BookmarksSheet menu (`ShareLink(item:
///    BookmarkClipTransferable(...))`).
/// 2. System share-sheet opens. The user picks a destination
///    (AirDrop, Messages, Save to Files, etc.).
/// 3. The system calls into the `FileRepresentation` exporter, which
///    runs `ClipExportCoordinator.stage(_:)` to produce the staged
///    MP4, then returns its URL via `SentTransferredFile`.
/// 4. The system copies / hands off the file to the destination app.
/// 5. `ClipExportCoordinator.pruneStaging` reclaims the cached file
///    on its next sweep.
///
/// Doing the staging inside the Transferable means we don't have to
/// pre-stage on every Bookmarks-row appear (wasteful — most rows are
/// never shared) and we get the system's own "Preparing…" UI during
/// the share-sheet ingestion.
public struct BookmarkClipTransferable: Sendable {
    public let request: ClipExportRequest
    /// Suggested filename surfaced in the share-sheet's title bar and
    /// any "Save to…" destinations. Should match the staged MP4's
    /// basename so the recipient sees a recognizable name.
    public let suggestedFilename: String

    public init(request: ClipExportRequest, suggestedFilename: String) {
        self.request = request
        self.suggestedFilename = suggestedFilename
    }
}

extension BookmarkClipTransferable: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { item in
            let staged = try await ClipExportCoordinator.stage(item.request)
            return SentTransferredFile(staged.stagedURL)
        }
        .suggestedFileName { $0.suggestedFilename + ".mp4" }
    }
}

extension BookmarkClipTransferable {
    /// Build a Transferable for a bookmark, given the source recording
    /// that contains it. Returns nil when the prerequisites for a
    /// lazy share aren't met: source recording's start time is
    /// unreadable, or the auto-downloader hasn't completed the local
    /// clip yet. Both BookmarksSheet callers route through this so
    /// the construction logic stays in one place.
    ///
    /// Source-file lookup itself lives in the caller because each
    /// shell has its own loader and matching strategy; passing the
    /// resolved `SearchFile` in keeps this helper free of any
    /// loader / view-state coupling.
    public static func make(
        bookmark: RecordingBookmark,
        sourceFile: SearchFile,
        cameraName: String
    ) -> BookmarkClipTransferable? {
        guard let fileStart = sourceFile.startDate else { return nil }
        let localFile = BookmarkAutoDownloader.localFileURL(for: bookmark)
        guard FileManager.default.fileExists(atPath: localFile.path) else { return nil }
        let lo = max(0, bookmark.startEpoch - fileStart.timeIntervalSince1970)
        let hi = max(lo, bookmark.endEpoch - fileStart.timeIntervalSince1970)
        let basename = ClipExportCoordinator.suggestedFilename(
            cameraName: cameraName,
            start: bookmark.startDate
        )
        return BookmarkClipTransferable(
            request: ClipExportRequest(
                sources: [.init(url: localFile, range: lo...hi)],
                suggestedFilename: basename
            ),
            suggestedFilename: basename
        )
    }
}

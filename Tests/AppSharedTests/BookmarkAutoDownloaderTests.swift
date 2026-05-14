import Testing
import Foundation
@testable import AppShared

/// 0.6.0 — `BookmarkAutoDownloader.enqueueIfMissing` is the path
/// users hit when tapping a bookmark whose local clip is missing
/// (download silently failed, app reinstalled, etc.). The actor's
/// network side requires a real `CameraSession` which can't be
/// constructed in a test, so these tests pin only the parts that
/// are reachable without one:
///
/// - `RecordingBookmark.sourceFileName` is optional and round-
///   trips through JSON encode/decode for forward-compat.
/// - `BookmarkAutoDownloader.EnqueueOutcome` is `Equatable` so call
///   sites can assert against it without string-comparing.
@Suite("RecordingBookmark.sourceFileName + EnqueueOutcome")
struct BookmarkAutoDownloaderTests {

    @Test("sourceFileName defaults to nil so legacy bookmarks_v1.json files decode cleanly")
    func sourceFileNameDefaultsNil() {
        let bookmark = RecordingBookmark(
            cameraID: UUID(),
            channel: 0,
            startEpoch: 0,
            endEpoch: 60
        )
        #expect(bookmark.sourceFileName == nil)
    }

    @Test("sourceFileName round-trips through JSON")
    func sourceFileNameRoundTrip() throws {
        let original = RecordingBookmark(
            cameraID: UUID(),
            channel: 1,
            startEpoch: 1_700_000_000,
            endEpoch: 1_700_000_060,
            sourceFileName: "Mp4Record/2026-05-14/RecS04_DST00.mp4"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingBookmark.self, from: data)
        #expect(decoded.sourceFileName == "Mp4Record/2026-05-14/RecS04_DST00.mp4")
    }

    @Test("Legacy JSON without sourceFileName decodes (forward-compat)")
    func legacyJSONDecodes() throws {
        // What a pre-0.6.0 `bookmarks_v1.json` row looks like — no
        // `sourceFileName` field. Forward-compat decoder must
        // surface `nil`, not throw.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "cameraID": "\(UUID().uuidString)",
          "channel": 0,
          "startEpoch": 1700000000,
          "endEpoch": 1700000060,
          "note": null,
          "aiTagsAtMark": [],
          "schemaVersion": 1
        }
        """
        let decoded = try JSONDecoder().decode(RecordingBookmark.self, from: Data(json.utf8))
        #expect(decoded.sourceFileName == nil)
        #expect(decoded.channel == 0)
    }

    @Test("EnqueueOutcome is Equatable across every case")
    func enqueueOutcomeIsEquatable() {
        #expect(BookmarkAutoDownloader.EnqueueOutcome.alreadyDownloaded == .alreadyDownloaded)
        #expect(BookmarkAutoDownloader.EnqueueOutcome.alreadyInFlight == .alreadyInFlight)
        #expect(BookmarkAutoDownloader.EnqueueOutcome.enqueued == .enqueued)
        #expect(BookmarkAutoDownloader.EnqueueOutcome.cannotResolveSource == .cannotResolveSource)
        #expect(BookmarkAutoDownloader.EnqueueOutcome.alreadyDownloaded != .enqueued)
    }

    @Test("hasLocalClip returns false for a bookmark whose clip was never downloaded")
    func hasLocalClipFalseWhenAbsent() {
        let bookmark = RecordingBookmark(
            cameraID: UUID(),
            channel: 0,
            startEpoch: 0,
            endEpoch: 60
        )
        // Fresh UUID means no clip file. The function should return
        // false rather than throwing or crashing.
        #expect(!BookmarkAutoDownloader.hasLocalClip(for: bookmark))
    }

    // MARK: - removeBookmark cleanup

    @Test("removeBookmark deletes the local clip file when one exists")
    func removeBookmarkDeletesLocalClip() async throws {
        let cameraID = UUID()
        let bookmark = RecordingBookmark(
            cameraID: cameraID,
            channel: 0,
            startEpoch: 100,
            endEpoch: 200,
            sourceFileName: "ignored.mp4"
        )
        // Plant a clip file at the bookmark's storage URL so the
        // cleanup helper has something to remove.
        let url = BookmarkAutoDownloader.localFileURL(for: bookmark)
        try Data("synthetic".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Also drop a JSON entry so the store-removal half exercises
        // the read-modify-write path. Using the production
        // `RecordingBookmarkStore` because the store URL is derived
        // from the iCloud container with a local-fallback that
        // tests can write to safely.
        try RecordingBookmarkStore.add(bookmark)
        #expect(RecordingBookmarkStore.read(cameraID: cameraID).count == 1)

        await BookmarkAutoDownloader.shared.removeBookmark(bookmark)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(RecordingBookmarkStore.read(cameraID: cameraID).isEmpty)
    }

    @Test("removeBookmark is a safe no-op when the bookmark has no local clip and no JSON entry")
    func removeBookmarkNoopOnFreshBookmark() async {
        let bookmark = RecordingBookmark(
            cameraID: UUID(),
            channel: 0,
            startEpoch: 0,
            endEpoch: 60
        )
        // Should complete without throwing even when there's
        // literally nothing to remove. This is the legacy-bookmark
        // path and the "tap delete twice fast" path.
        await BookmarkAutoDownloader.shared.removeBookmark(bookmark)
        #expect(!BookmarkAutoDownloader.hasLocalClip(for: bookmark))
    }

    @Test("removeBookmark leaves OTHER cameras' bookmarks untouched")
    func removeBookmarkScopedToCamera() async throws {
        let cameraA = UUID()
        let cameraB = UUID()
        let bookmarkA = RecordingBookmark(cameraID: cameraA, channel: 0, startEpoch: 0, endEpoch: 60)
        let bookmarkB = RecordingBookmark(cameraID: cameraB, channel: 0, startEpoch: 0, endEpoch: 60)
        try RecordingBookmarkStore.add(bookmarkA)
        try RecordingBookmarkStore.add(bookmarkB)

        await BookmarkAutoDownloader.shared.removeBookmark(bookmarkA)

        #expect(RecordingBookmarkStore.read(cameraID: cameraA).isEmpty)
        #expect(RecordingBookmarkStore.read(cameraID: cameraB).count == 1)
        // Teardown so the test doesn't leave cross-test detritus.
        try? RecordingBookmarkStore.remove(id: bookmarkB.id, cameraID: cameraB)
    }
}

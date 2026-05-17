import Testing
import Foundation
@testable import AppShared

/// 0.6.2 — `ClipExportCoordinator` is the file-side foundation for
/// the unified export storyline. AVFoundation composition isn't
/// exercised here (covered by the existing `ClipExporter` integration
/// path); these tests pin the pure-Swift helpers that the UI calls
/// every time it stages an export: the filename builder, the staging
/// directory, the cleanup pruner.
@Suite("ClipExportCoordinator file-side helpers")
struct ClipExportCoordinatorTests {

    // MARK: - Filename builder

    @Test("Suggested filename composes a recognizable basename")
    func filenameBasename() {
        let start = Date(timeIntervalSince1970: 1_715_802_764) // 2024-05-15 19:52:44 UTC
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "Driveway",
            start: start
        )
        #expect(name == "Driveway_2024-05-15_19-52-44")
    }

    @Test("Sanitizer collapses spaces, slashes, and punctuation to single underscores")
    func filenameSanitization() {
        let start = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00:00 UTC
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "Front Door / Camera 2!",
            start: start
        )
        // Spaces, slash, exclamation collapse — runs of underscores
        // flatten to one.
        #expect(name == "Front_Door_Camera_2_1970-01-01_00-00-00")
    }

    @Test("Empty camera name falls back to Clip prefix instead of leading underscore")
    func filenameEmptyName() {
        let start = Date(timeIntervalSince1970: 0)
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "",
            start: start
        )
        #expect(name == "Clip_1970-01-01_00-00-00")
    }

    @Test("All-disallowed name collapses to Clip prefix (no leading / trailing underscore)")
    func filenameAllDisallowed() {
        let start = Date(timeIntervalSince1970: 0)
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "!!!",
            start: start
        )
        #expect(name == "Clip_1970-01-01_00-00-00")
    }

    @Test("Filename respects the caller's time zone")
    func filenameTimeZone() {
        let start = Date(timeIntervalSince1970: 1_715_802_764) // 2024-05-15 19:52:44 UTC
        let pacific = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "Backyard",
            start: start,
            timeZone: pacific
        )
        // 12:52:44 local time on 2024-05-15 in PDT
        #expect(name == "Backyard_2024-05-15_12-52-44")
    }

    @Test("Dashes survive the sanitizer (already valid filesystem characters)")
    func filenameDashesSurvive() {
        let start = Date(timeIntervalSince1970: 0)
        let name = ClipExportCoordinator.suggestedFilename(
            cameraName: "Side-Yard",
            start: start
        )
        #expect(name == "Side-Yard_1970-01-01_00-00-00")
    }

    // MARK: - Staging directory

    @Test("Ensuring the staging directory creates it under caches/Reolens/exports")
    func stagingDirectoryCreated() throws {
        let dir = try ClipExportCoordinator.ensureStagingDirectory()
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(dir.lastPathComponent == "exports")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Reolens")
    }

    @Test("stagedURL returns an MP4 path inside the staging directory")
    func stagedURLPath() throws {
        let request = ClipExportRequest(
            sources: [],
            suggestedFilename: "Driveway_2026-05-15_19-32-00"
        )
        let url = try ClipExportCoordinator.stagedURL(for: request)
        #expect(url.pathExtension == "mp4")
        #expect(url.lastPathComponent == "Driveway_2026-05-15_19-32-00.mp4")
        #expect(url.deletingLastPathComponent() == ClipExportCoordinator.stagingDirectory)
    }

    @Test("stagedURL falls back to a timestamp-based name when none is supplied")
    func stagedURLFallback() throws {
        let request = ClipExportRequest(sources: [])
        let fixedNow = Date(timeIntervalSince1970: 1_715_802_764)
        let url = try ClipExportCoordinator.stagedURL(for: request, now: fixedNow)
        #expect(url.pathExtension == "mp4")
        #expect(url.lastPathComponent == "Clip_2024-05-15_19-52-44.mp4")
    }

    @Test("stagedURL re-sanitizes a user-supplied filename so unsafe input can't escape the staging dir")
    func stagedURLSanitizesUserInput() throws {
        let request = ClipExportRequest(
            sources: [],
            suggestedFilename: "../etc/passwd"
        )
        let url = try ClipExportCoordinator.stagedURL(for: request)
        // The path traversal collapses to safe underscores; the file
        // still lands inside the staging directory.
        #expect(url.deletingLastPathComponent() == ClipExportCoordinator.stagingDirectory)
        #expect(!url.path.contains("/etc/"))
    }

    // MARK: - Cleanup

    @Test("Prune removes files older than the cutoff, keeps fresh files")
    func pruneEvictsOldFilesOnly() throws {
        let dir = try ClipExportCoordinator.ensureStagingDirectory()
        // Two scratch files: one stamped well in the past, one fresh.
        let oldURL = dir.appendingPathComponent("test_prune_old.mp4")
        let freshURL = dir.appendingPathComponent("test_prune_fresh.mp4")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.removeItem(at: freshURL)
        FileManager.default.createFile(atPath: oldURL.path, contents: Data([0x00]))
        FileManager.default.createFile(atPath: freshURL.path, contents: Data([0x00]))
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: twoHoursAgo],
            ofItemAtPath: oldURL.path
        )

        // Don't assert on the returned count — the staging
        // directory is shared across tests (and across CI
        // workers) so concurrent prunes can leave it racy.
        // The per-file assertions below are the real
        // contract: this run's `oldURL` was removed and this
        // run's `freshURL` survived.
        _ = ClipExportCoordinator.pruneStaging(olderThan: 3600)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: freshURL.path))
        try? FileManager.default.removeItem(at: freshURL)
    }

    @Test("Prune never crashes — fresh-launch path where the directory hasn't been created yet")
    func pruneToleratesMissingDirectory() {
        // The function's contract is "return Int, never throw" so a
        // device that's never exported a clip (and therefore has no
        // staging directory) calls it safely from the launch hook.
        let removed = ClipExportCoordinator.pruneStaging(olderThan: 60)
        #expect(removed >= 0)
    }
}

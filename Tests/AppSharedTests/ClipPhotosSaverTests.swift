import Testing
import Foundation
@testable import AppShared

/// 0.6.2 — `ClipPhotosSaver` wraps `PHPhotoLibrary` on iOS. The Photos
/// framework can't be exercised in a unit-test host (no permission
/// dialog, no library), so only the pre-flight branches that don't
/// touch `PHPhotoLibrary` are pinned here:
/// - `.noFile` when the staged URL doesn't exist
/// - `.unsupported` on macOS (no native camera roll surface)
@Suite("ClipPhotosSaver pre-flight branches")
struct ClipPhotosSaverTests {

    @Test("Missing file returns .noFile before any Photos authorization is requested")
    func missingFileReturnsNoFile() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        let result = await ClipPhotosSaver.save(videoFileURL: bogus)
        #expect(result == .noFile)
    }

    @Test("macOS returns .unsupported even when the file exists (no native camera roll)")
    func macOSReturnsUnsupported() async throws {
        #if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-clip-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await ClipPhotosSaver.save(videoFileURL: tmp)
        #expect(result == .unsupported)
        #else
        // On iOS the same call would trigger `PHPhotoLibrary.requestAuthorization`
        // which requires user interaction — skip rather than fail.
        #endif
    }
}

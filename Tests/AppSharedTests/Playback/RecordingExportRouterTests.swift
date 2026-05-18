import Foundation
import Testing
@testable import AppShared
import ReolinkAPI

@Suite("RecordingExportRouter — filename generation")
struct RecordingExportRouterTests {

    private func sampleRecording(cameraName: String, startEpoch: TimeInterval) -> PlayableRecording {
        PlayableRecording(
            id: "clip",
            displayName: "clip.mp4",
            cameraID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            cameraName: cameraName,
            channel: 0,
            startDate: Date(timeIntervalSince1970: startEpoch),
            endDate: nil,
            highQuality: .init(
                url: URL(string: "https://hub.test/cgi-bin/api.cgi?cmd=Download&source=main.mp4")!,
                file: nil
            ),
            lowQuality: nil,
            initialQuality: .high
        )
    }

    @Test("Basename carries camera, date, and quality")
    func basenameShape() {
        let recording = sampleRecording(cameraName: "Driveway", startEpoch: 1747700000)
        let basename = RecordingExportRouter.suggestedBasename(
            for: recording,
            quality: .high,
            trimmed: false
        )
        #expect(basename.contains("Driveway"))
        #expect(basename.contains("HD"))
        #expect(!basename.contains(".mp4"))
    }

    @Test("Trimmed basename gets a clip suffix")
    func trimmedBasename() {
        let recording = sampleRecording(cameraName: "Driveway", startEpoch: 1747700000)
        let basename = RecordingExportRouter.suggestedBasename(
            for: recording,
            quality: .low,
            trimmed: true
        )
        #expect(basename.contains("SD"))
        #expect(basename.hasSuffix("clip"))
    }

    @Test("Full filename ends with .mp4")
    func filenameSuffix() {
        let recording = sampleRecording(cameraName: "Driveway", startEpoch: 1747700000)
        let filename = RecordingExportRouter.suggestedFilename(
            for: recording,
            quality: .high,
            trimmed: false
        )
        #expect(filename.hasSuffix(".mp4"))
    }

    @Test("Camera names with punctuation collapse to underscores")
    func sanitizedCameraName() {
        let recording = sampleRecording(cameraName: "Front Door / Camera!", startEpoch: 1747700000)
        let basename = RecordingExportRouter.suggestedBasename(
            for: recording,
            quality: .high,
            trimmed: false
        )
        // Sanitizer maps disallowed chars to underscores and collapses
        // runs, so "Front Door / Camera!" becomes "Front_Door_Camera".
        #expect(basename.contains("Front_Door_Camera"))
        #expect(!basename.contains(" "))
        #expect(!basename.contains("/"))
        #expect(!basename.contains("!"))
    }
}

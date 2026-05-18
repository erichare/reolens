import Foundation
import Testing
@testable import AppShared
import ReolinkAPI

@Suite("PlayableRecording — quality variant resolution")
struct PlayableRecordingTests {

    private func makeVariant(name: String, sizeMB: Int = 5) -> PlayableRecording.Variant {
        PlayableRecording.Variant(
            url: URL(string: "https://hub.test/cgi-bin/api.cgi?cmd=Download&source=\(name)")!,
            file: nil,
            expectedSize: Int64(sizeMB * 1024 * 1024)
        )
    }

    @Test("Both qualities present — initialQuality honored")
    func bothVariantsHonored() {
        let recording = PlayableRecording(
            id: "clip-1",
            displayName: "clip-1.mp4",
            cameraID: UUID(),
            cameraName: "Driveway",
            channel: 0,
            startDate: nil,
            endDate: nil,
            highQuality: makeVariant(name: "main.mp4"),
            lowQuality: makeVariant(name: "sub.mp4"),
            initialQuality: .low
        )
        #expect(recording.initialQuality == .low)
        #expect(recording.canSwitchQuality)
        #expect(recording.availableQualities == [.low, .high])
    }

    @Test("Only high variant — initialQuality falls back to high")
    func onlyHighFallsBack() {
        let recording = PlayableRecording(
            id: "clip-2",
            displayName: "clip-2.mp4",
            cameraID: UUID(),
            cameraName: "Driveway",
            channel: 0,
            startDate: nil,
            endDate: nil,
            highQuality: makeVariant(name: "main.mp4"),
            lowQuality: nil,
            initialQuality: .low
        )
        #expect(recording.initialQuality == .high)
        #expect(!recording.canSwitchQuality)
        #expect(recording.availableQualities == [.high])
    }

    @Test("Only low variant — initialQuality falls back to low")
    func onlyLowFallsBack() {
        let recording = PlayableRecording(
            id: "clip-3",
            displayName: "clip-3.mp4",
            cameraID: UUID(),
            cameraName: "Driveway",
            channel: 0,
            startDate: nil,
            endDate: nil,
            highQuality: nil,
            lowQuality: makeVariant(name: "sub.mp4"),
            initialQuality: .high
        )
        #expect(recording.initialQuality == .low)
        #expect(!recording.canSwitchQuality)
        #expect(recording.availableQualities == [.low])
    }

    @Test("Variant lookup returns the right variant per quality")
    func variantLookup() {
        let high = makeVariant(name: "main.mp4")
        let low = makeVariant(name: "sub.mp4")
        let recording = PlayableRecording(
            id: "clip-4",
            displayName: "clip-4.mp4",
            cameraID: UUID(),
            cameraName: "Driveway",
            channel: 0,
            startDate: nil,
            endDate: nil,
            highQuality: high,
            lowQuality: low,
            initialQuality: .low
        )
        #expect(recording.variant(for: .low)?.url == low.url)
        #expect(recording.variant(for: .high)?.url == high.url)
    }
}

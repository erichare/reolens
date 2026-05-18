import Foundation
import Testing
@testable import AppShared

@Suite("RecordingQuality — helpers")
struct RecordingQualityTests {

    @Test("flipped toggles between low and high")
    func flipped() {
        #expect(RecordingQuality.low.flipped == .high)
        #expect(RecordingQuality.high.flipped == .low)
    }

    @Test("label and longLabel are non-empty")
    func labels() {
        for quality in RecordingQuality.allCases {
            #expect(!quality.label.isEmpty)
            #expect(!quality.longLabel.isEmpty)
            #expect(quality.longLabel.lowercased().contains("quality"))
        }
    }

    @Test("rawValue round-trips for UserDefaults storage")
    func rawValueRoundTrip() {
        for quality in RecordingQuality.allCases {
            let raw = quality.rawValue
            #expect(RecordingQuality(rawValue: raw) == quality)
        }
    }
}

@Suite("RecordingExportDestination — platform availability")
struct RecordingExportDestinationTests {

    @Test("Available list is non-empty and contains .file")
    func availableContainsFile() {
        let available = RecordingExportDestination.available
        #expect(!available.isEmpty)
        #expect(available.contains(.file))
    }

    @Test("Each destination carries a label and system image")
    func metadata() {
        for destination in RecordingExportDestination.allCases {
            #expect(!destination.label.isEmpty)
            #expect(!destination.systemImage.isEmpty)
        }
    }
}

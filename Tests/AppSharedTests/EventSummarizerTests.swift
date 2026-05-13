import Testing
import Foundation
import ReolinkAPI
@testable import AppShared

/// 0.5.1 — `EventSummarizer` must always return *something*, including
/// on devices without Apple Intelligence. The deterministic fallback
/// is the only path we can assert exact strings against — the
/// FoundationModels path is non-deterministic by design and is covered
/// by integration tests on real devices.
@Suite("EventSummarizer — deterministic fallback")
struct EventSummarizerTests {

    @Test("Empty input yields a 'no activity' headline")
    func emptyInputHeadline() {
        let summarizer = EventSummarizer()
        let digest = summarizer.fallbackDigest(perCamera: [])
        #expect(digest.headline == "No activity today.")
        #expect(digest.bulletPoints.isEmpty)
        #expect(digest.source == .fallback)
    }

    @Test("Headline reports total clip count and top triggers")
    func headlineReportsTotalAndTriggers() {
        let summarizer = EventSummarizer()
        let cam = EventSummarizer.CameraSummary(
            cameraID: UUID(),
            cameraName: "Driveway",
            totalClips: 3,
            triggers: [.person: 2, .vehicle: 1]
        )
        let digest = summarizer.fallbackDigest(perCamera: [cam])
        #expect(digest.source == .fallback)
        #expect(digest.headline.contains("3"))
        #expect(digest.headline.lowercased().contains("person"))
    }

    @Test("Bullet points list the busiest cameras")
    func bulletsListBusiest() {
        let summarizer = EventSummarizer()
        let backYard = EventSummarizer.CameraSummary(
            cameraID: UUID(),
            cameraName: "Back Yard",
            totalClips: 5,
            triggers: [.pet: 5]
        )
        let frontDoor = EventSummarizer.CameraSummary(
            cameraID: UUID(),
            cameraName: "Front Door",
            totalClips: 1,
            triggers: [.visitor: 1]
        )
        let digest = summarizer.fallbackDigest(perCamera: [backYard, frontDoor])
        // Busiest camera listed first.
        #expect(digest.bulletPoints.first?.contains("Back Yard") == true)
    }

    @Test("Cameras with zero clips don't pollute the bullet list")
    func quietCamerasOmitted() {
        let summarizer = EventSummarizer()
        let quiet = EventSummarizer.CameraSummary(
            cameraID: UUID(),
            cameraName: "Garage",
            totalClips: 0,
            triggers: [:]
        )
        let busy = EventSummarizer.CameraSummary(
            cameraID: UUID(),
            cameraName: "Driveway",
            totalClips: 2,
            triggers: [.vehicle: 2]
        )
        let digest = summarizer.fallbackDigest(perCamera: [quiet, busy])
        #expect(digest.bulletPoints.allSatisfy { !$0.contains("Garage") })
        #expect(digest.bulletPoints.contains(where: { $0.contains("Driveway") }))
    }
}

import Testing
import Foundation
@testable import AppShared
import ReolinkAPI

/// 0.6.0 — `RecordingNLSearcher` is the deterministic prompt → query
/// translator. The FoundationModels path is hardware-gated and tested
/// separately by manual QA on Apple Intelligence devices. These tests
/// pin the deterministic parser's behaviour against the documented
/// prompt forms.
@Suite("RecordingNLSearcher (deterministic)")
struct RecordingNLSearcherTests {

    // MARK: - Tag parsing

    @Test("\"packages this week\" extracts the packageDelivery tag")
    func tagSingularPlural() {
        let searcher = RecordingNLSearcher()
        let q = searcher.plan(prompt: "packages this week")
        #expect(q.tagFilter == [.packageDelivery])
    }

    @Test("\"any vehicles or people yesterday\" extracts both tags")
    func tagMultiple() {
        let searcher = RecordingNLSearcher()
        let q = searcher.plan(prompt: "any vehicles or people yesterday")
        #expect(q.tagFilter == [.vehicle, .person])
    }

    @Test("\"visitor at the door\" maps doorbell-style language to visitor tag")
    func tagDoorbellSynonym() {
        let searcher = RecordingNLSearcher()
        let q = searcher.plan(prompt: "any visitor at the door")
        #expect(q.tagFilter.contains(.visitor))
    }

    @Test("Empty prompt produces an empty (= unfiltered) query")
    func emptyPrompt() {
        let searcher = RecordingNLSearcher()
        let q = searcher.plan(prompt: "   ")
        #expect(q.tagFilter.isEmpty)
        #expect(q.dateRange == nil)
        #expect(q.cameraIDs.isEmpty)
    }

    // MARK: - Date parsing

    @Test("\"today\" yields a today-anchored range covering the full day")
    func dateToday() {
        let searcher = RecordingNLSearcher()
        let now = anchorDate(hour: 14)
        let q = searcher.plan(prompt: "people today", now: now)
        let range = q.dateRange
        try? #require(range != nil)
        let cal = Calendar.current
        #expect(cal.isDate(range!.lowerBound, inSameDayAs: now))
        #expect(cal.isDate(range!.upperBound, inSameDayAs: now))
    }

    @Test("\"yesterday\" yields a yesterday-anchored range")
    func dateYesterday() {
        let searcher = RecordingNLSearcher()
        let now = anchorDate(hour: 14)
        let q = searcher.plan(prompt: "vehicles yesterday", now: now)
        let range = q.dateRange
        try? #require(range != nil)
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        #expect(cal.isDate(range!.lowerBound, inSameDayAs: yesterday))
        #expect(cal.isDate(range!.upperBound, inSameDayAs: yesterday))
    }

    @Test("\"last 7 days\" yields a week-anchored range")
    func dateLastNDays() {
        let searcher = RecordingNLSearcher()
        let now = anchorDate(hour: 14)
        let q = searcher.plan(prompt: "any people last 7 days", now: now)
        let range = q.dateRange
        try? #require(range != nil)
        let days = Calendar.current.dateComponents(
            [.day],
            from: range!.lowerBound,
            to: range!.upperBound
        ).day ?? 0
        #expect(days == 7)
    }

    @Test("\"this week\" yields a range starting at the week's start")
    func dateThisWeek() {
        let searcher = RecordingNLSearcher()
        let now = anchorDate(hour: 14)
        let q = searcher.plan(prompt: "anything this week", now: now)
        let range = q.dateRange
        try? #require(range != nil)
        // Lower bound must be the start of the week containing `now`.
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: now)!.start
        #expect(range!.lowerBound == weekStart)
    }

    // MARK: - Camera parsing

    @Test("Camera name token in prompt restricts to that camera's ID")
    func cameraTokenMatch() {
        let searcher = RecordingNLSearcher()
        let driveway = RecordingNLSearcher.CameraHint(cameraID: UUID(), name: "Driveway")
        let porch = RecordingNLSearcher.CameraHint(cameraID: UUID(), name: "Porch")
        let q = searcher.plan(
            prompt: "people at the driveway",
            availableCameras: [driveway, porch]
        )
        #expect(q.cameraIDs == [driveway.cameraID])
    }

    @Test("Generic camera words (\"camera\", \"channel\") don't match every camera")
    func cameraStopwordsFilter() {
        let searcher = RecordingNLSearcher()
        let hint = RecordingNLSearcher.CameraHint(cameraID: UUID(), name: "Camera 1")
        let q = searcher.plan(
            prompt: "anything on the camera",
            availableCameras: [hint]
        )
        #expect(q.cameraIDs.isEmpty)
    }

    // MARK: - Helpers

    /// Construct a Date anchored to a known hour of today so the
    /// today / yesterday / week tests are stable.
    private func anchorDate(hour: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    }
}

/// 0.6.0 — `RecordingNLSearcher.merge(deterministic:model:)` is the
/// merge policy between the two interpreters. Hardware-gated paths
/// (`planWithModel` / `foundationModelsPlan`) can't run under unit
/// tests because FoundationModels availability depends on Apple
/// Intelligence eligibility; the merge logic doesn't, so we pin it.
@Suite("RecordingNLSearcher.merge")
struct RecordingNLSearcherMergeTests {

    @Test("Union the tag filters from both sources")
    func tagsAreUnion() {
        let det = RecordingIndex.Query(tagFilter: [.person])
        let model = RecordingIndex.Query(tagFilter: [.vehicle])
        let merged = RecordingNLSearcher.merge(deterministic: det, model: model)
        #expect(merged.tagFilter == [.person, .vehicle])
    }

    @Test("Union the camera-ID filters from both sources")
    func camerasAreUnion() {
        let a = UUID()
        let b = UUID()
        let det = RecordingIndex.Query(cameraIDs: [a])
        let model = RecordingIndex.Query(cameraIDs: [b])
        let merged = RecordingNLSearcher.merge(deterministic: det, model: model)
        #expect(merged.cameraIDs == [a, b])
    }

    @Test("Deterministic dateRange wins when set")
    func dateRangePrefersDeterministic() {
        let now = Date()
        let day: ClosedRange<Date> = now...(now.addingTimeInterval(3600))
        let detRange: ClosedRange<Date> = now...(now.addingTimeInterval(60))
        let det = RecordingIndex.Query(dateRange: detRange)
        let model = RecordingIndex.Query(dateRange: day)
        let merged = RecordingNLSearcher.merge(deterministic: det, model: model)
        #expect(merged.dateRange == detRange)
    }

    @Test("Model dateRange fills the gap when deterministic has none")
    func dateRangeFallsBackToModel() {
        let now = Date()
        let modelRange: ClosedRange<Date> = now...(now.addingTimeInterval(60))
        let det = RecordingIndex.Query()
        let model = RecordingIndex.Query(dateRange: modelRange)
        let merged = RecordingNLSearcher.merge(deterministic: det, model: model)
        #expect(merged.dateRange == modelRange)
    }

    @Test("planWithModel returns the deterministic baseline when the model is absent")
    func planWithModelMatchesBaselineWhenUnavailable() async {
        // On CI / test machines FoundationModels typically returns
        // `.unavailable`; the `planWithModel` path then resolves to
        // exactly the deterministic plan. This is the contract we
        // need to verify — the model path NEVER produces a *worse*
        // result than the deterministic one alone.
        let searcher = RecordingNLSearcher()
        let baseline = searcher.plan(prompt: "people today")
        let modelAware = await searcher.planWithModel(prompt: "people today")
        // On most test hosts the model path will fall through to
        // the deterministic baseline. When the model IS available
        // (very rare in CI), the merged result must still be a
        // *superset* (tags and camera filters can only grow).
        #expect(modelAware.tagFilter.isSuperset(of: baseline.tagFilter))
        #expect(modelAware.cameraIDs.isSuperset(of: baseline.cameraIDs))
        // Date range stays exactly equal — deterministic wins per the
        // merge policy.
        #expect(modelAware.dateRange == baseline.dateRange)
    }
}

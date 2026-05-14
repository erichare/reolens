import Testing
import Foundation
@testable import AppShared
import ReolinkAPI
import ReolinkBaichuan

/// 0.6.0 — `RecordingsLoader` covers the foundation pulled out of the
/// duplicated macOS/iOS RecordingsView reload paths. Tests target the
/// invariants Slices 11/12/13 will rely on:
///
/// - Main → sub serialization (Home Hub Pro `rcv failed` mitigation).
/// - Generation guard drops stale reloads on rapid date flips.
/// - Three-tier `effectiveDetections()` fallback ordering.
/// - `effectiveDetections()` memoization invalidates on input change.
/// - `subFileMatch(for:)` longest-overlap selection.
/// - `searchWindow(for:)` rejects future days.
@MainActor
@Suite("RecordingsLoader")
struct RecordingsLoaderTests {

    // MARK: - Loading + phase

    @Test("Successful main Search transitions phase idle → loading → ready and populates files")
    func happyPath() async {
        let source = FakeRecordingsDataSource()
        source.queueMainResult(.success([file(name: "m1", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        let loader = makeLoader(source: source)

        await loader.reload()

        #expect(loader.phase == .ready)
        #expect(loader.files.count == 1)
        #expect(loader.errorMessage == nil)
        #expect(loader.isLoading == false)
    }

    @Test("Failed main Search surfaces errorMessage and clears files")
    func failurePath() async {
        let source = FakeRecordingsDataSource()
        // First populate files via a successful reload, then verify a
        // subsequent failure clears them.
        source.queueMainResult(.success([file(name: "first", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        let loader = makeLoader(source: source)
        await loader.reload()
        #expect(loader.files.count == 1)

        source.queueMainResult(.failure("camera busy"))
        await loader.reload()

        #expect(loader.errorMessage == "camera busy")
        #expect(loader.files.isEmpty)
    }

    @Test("Disconnected session yields the not-connected error message and does not call Search")
    func notConnected() async {
        let source = FakeRecordingsDataSource()
        source.shouldConnect = false
        let loader = makeLoader(source: source)

        await loader.reload()

        #expect(loader.errorMessage?.contains("isn't connected") == true)
        #expect(source.searchCalls.isEmpty)
    }

    // MARK: - Ordering: main → sub serialization

    @Test("Sub-stream Search never starts before main returns")
    func mainBeforeSub() async {
        let source = FakeRecordingsDataSource()
        source.recordSearchTimings = true
        source.queueMainResult(.success([file(name: "m1", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([file(name: "s1", startOffset: 0)], rawPretty: "", statuses: []))
        source.mainSearchDelay = .milliseconds(80)
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForSubSearch()

        let main = source.searchCalls.first { $0.streamType == "main" }
        let sub = source.searchCalls.first { $0.streamType == "sub" }
        try? #require(main != nil && sub != nil)
        // sub starts AT OR AFTER main finishes — the ±1ms slack covers
        // MainActor scheduler quantization between the two records.
        #expect(sub!.startedAt >= main!.finishedAt - 0.001)
    }

    // MARK: - Generation guard

    @Test("Rapid second reload causes the first reload to drop its writes")
    func generationGuardDropsStale() async {
        let source = FakeRecordingsDataSource()
        // First reload: hang main until we release it.
        let firstReleased = AsyncSignal()
        source.queueMainResult(.success([file(name: "stale-A", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.mainSearchGate = firstReleased
        let loader = makeLoader(source: source)

        // Kick off the first reload in a background task; it suspends at main.
        let firstTask = Task { await loader.reload() }
        await Task.yield()

        // While first is suspended, prep the second reload's responses and
        // bump the generation by calling reload again. Second uses no gate
        // so it returns immediately.
        source.mainSearchGate = nil
        source.queueMainResult(.success([file(name: "fresh-B", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        await loader.reload()

        // Now release the first reload's main Search. Its publication
        // path should detect the generation mismatch and bail.
        firstReleased.release()
        await firstTask.value

        #expect(loader.files.map(\.name) == ["fresh-B"])
    }

    @Test("cancel() bumps the generation and drops the in-flight reload")
    func explicitCancel() async {
        let source = FakeRecordingsDataSource()
        let gate = AsyncSignal()
        source.queueMainResult(.success([file(name: "stale", startOffset: 0)], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.mainSearchGate = gate
        let loader = makeLoader(source: source)

        let task = Task { await loader.reload() }
        await Task.yield()

        loader.cancel()
        gate.release()
        await task.value

        // The reload was cancelled before main returned; files stays empty.
        #expect(loader.files.isEmpty)
    }

    // MARK: - effectiveDetections three-tier fallback

    @Test("Tier 1: SearchFile.triggers takes precedence over Baichuan + eventLog")
    func tier1Triggers() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: DetectionType.person.bit)
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        // Baichuan would say "vehicle"; eventLog would say "package". Tier 1 wins.
        source.alarmVideosForFindCall = [alarmVideo(name: "f1", offset: 0, alarmType: "vehicle")]
        source.eventsResult = .events([hubEvent(offset: 0, detections: [.packageDelivery])])
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()
        await source.waitForEvents()

        let f0 = loader.files[0]
        #expect(loader.effectiveDetections(for: f0) == [.person])
    }

    @Test("Tier 2: Baichuan overlap used when SearchFile.triggers is empty")
    func tier2Baichuan() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: 0)
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        // Baichuan reports "people, vehicle" overlapping the file's range.
        source.alarmVideosForFindCall = [alarmVideo(name: "f1", offset: 0, alarmType: "people, vehicle")]
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()

        let detections = loader.effectiveDetections(for: loader.files[0])
        #expect(Set(detections) == [.person, .vehicle])
    }

    @Test("Tier 3: live aiEventLog used when triggers + Baichuan empty")
    func tier3AIEventLog() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: 0)
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.alarmVideosForFindCall = []
        source.currentAIEventLog = [
            TimestampedAIEvent(
                timestamp: f.startDate!.addingTimeInterval(30),
                channelID: 0,
                kind: .ai("people"),
                aiTag: "people"
            )
        ]
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()
        await source.waitForEvents()

        #expect(loader.effectiveDetections(for: loader.files[0]) == [.person])
    }

    @Test("Tier 4: speculative GetEvents probe is the last fallback")
    func tier4GetEvents() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: 0)
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.alarmVideosForFindCall = []
        source.currentAIEventLog = []
        source.eventsResult = .events([hubEvent(offset: 30, detections: [.visitor])])
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()
        await source.waitForEvents()

        #expect(loader.effectiveDetections(for: loader.files[0]) == [.visitor])
    }

    // MARK: - Memoization

    @Test("effectiveDetections returns cached value on repeated call (memoization)")
    func memoizationHit() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: 0)
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.alarmVideosForFindCall = [alarmVideo(name: "f1", offset: 0, alarmType: "people")]
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()

        let first = loader.effectiveDetections(for: loader.files[0])
        let second = loader.effectiveDetections(for: loader.files[0])
        #expect(first == second)
        #expect(first == [.person])
    }

    @Test("Memoization cache invalidates when alarmVideoEntries changes via a fresh reload")
    func memoizationInvalidates() async {
        let source = FakeRecordingsDataSource()
        let f = file(name: "f1", startOffset: 0, triggerMask: 0)
        // First reload: no Baichuan tag.
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.alarmVideosForFindCall = []
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForAlarmVideos()
        #expect(loader.effectiveDetections(for: loader.files[0]).isEmpty)

        // Second reload: Baichuan now reports "vehicle". Cache must
        // reflect the new tag, not the prior empty result.
        source.queueMainResult(.success([f], rawPretty: "", statuses: []))
        source.queueSubResult(.success([], rawPretty: "", statuses: []))
        source.alarmVideosForFindCall = [alarmVideo(name: "f1", offset: 0, alarmType: "vehicle")]
        await loader.reload()
        await source.waitForAlarmVideos()

        #expect(loader.effectiveDetections(for: loader.files[0]) == [.vehicle])
    }

    // MARK: - subFileMatch

    @Test("subFileMatch returns the sub with the largest temporal overlap")
    func subFileMatchPicksLongestOverlap() async {
        let source = FakeRecordingsDataSource()
        let main = file(name: "main1", startOffset: 0, durationSeconds: 60)
        let subShort = file(name: "subShort", startOffset: 50, durationSeconds: 20)
        let subLong = file(name: "subLong", startOffset: 5, durationSeconds: 50)
        source.queueMainResult(.success([main], rawPretty: "", statuses: []))
        source.queueSubResult(.success([subShort, subLong], rawPretty: "", statuses: []))
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForSubSearch()

        #expect(loader.subFileMatch(for: main)?.name == "subLong")
    }

    @Test("subFileMatch returns nil when no sub overlaps")
    func subFileMatchNoOverlap() async {
        let source = FakeRecordingsDataSource()
        let main = file(name: "main1", startOffset: 0, durationSeconds: 10)
        let subFar = file(name: "subFar", startOffset: 1000, durationSeconds: 10)
        source.queueMainResult(.success([main], rawPretty: "", statuses: []))
        source.queueSubResult(.success([subFar], rawPretty: "", statuses: []))
        let loader = makeLoader(source: source)

        await loader.reload()
        await source.waitForSubSearch()

        #expect(loader.subFileMatch(for: main) == nil)
    }

    // MARK: - searchWindow

    @Test("searchWindow returns nil for a future day")
    func searchWindowFuture() {
        let future = Date().addingTimeInterval(7 * 24 * 3600)
        #expect(RecordingsLoader.searchWindow(for: future) == nil)
    }

    @Test("searchWindow caps end at now for today")
    func searchWindowTodayCappedAtNow() {
        let now = Date()
        guard let window = RecordingsLoader.searchWindow(for: now) else {
            Issue.record("Expected non-nil window for today")
            return
        }
        #expect(window.end <= now.addingTimeInterval(1))
    }

    // MARK: - Helpers

    private func makeLoader(source: FakeRecordingsDataSource) -> RecordingsLoader {
        RecordingsLoader(
            source: source,
            channel: 0,
            channelUID: nil,
            captureRawResponses: false,
            initialDate: Date()
        )
    }

    private func file(
        name: String,
        startOffset: TimeInterval,
        durationSeconds: TimeInterval = 60,
        triggerMask: Int = 0
    ) -> SearchFile {
        let now = Self.fixedNow
        let start = now.addingTimeInterval(-3600 + startOffset)
        let end = start.addingTimeInterval(durationSeconds)
        let json = """
        {
          "name": "\(name)",
          "size": 1000,
          "type": "main",
          "StartTime": \(reolinkTimeJSON(date: start)),
          "EndTime": \(reolinkTimeJSON(date: end)),
          "frameRate": 30,
          "width": 1920,
          "height": 1080,
          \(triggerMask != 0 ? "\"trigger\": \(triggerMask)," : "")
          "PlaybackTime": \(reolinkTimeJSON(date: start))
        }
        """
        return try! JSONDecoder().decode(SearchFile.self, from: Data(json.utf8))
    }

    private func alarmVideo(name: String, offset: TimeInterval, alarmType: String) -> BaichuanAlarmVideoFile {
        let now = Self.fixedNow
        let start = now.addingTimeInterval(-3600 + offset)
        let end = start.addingTimeInterval(60)
        return BaichuanAlarmVideoFile(
            fileName: name,
            startTime: ReolinkTime(date: start),
            endTime: ReolinkTime(date: end),
            alarmType: alarmType
        )
    }

    private func hubEvent(offset: TimeInterval, detections: [DetectionType]) -> HubEvent {
        let now = Self.fixedNow
        let start = now.addingTimeInterval(-3600 + offset)
        return HubEvent(
            id: "ev-\(Int(offset))",
            startTime: start,
            endTime: start.addingTimeInterval(5),
            detectionTypes: detections
        )
    }

    private func reolinkTimeJSON(date: Date) -> String {
        let c = Calendar.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return "{\"year\": \(c.year!), \"mon\": \(c.month!), \"day\": \(c.day!), \"hour\": \(c.hour!), \"min\": \(c.minute!), \"sec\": \(c.second!)}"
    }

    /// Anchor used for synthetic SearchFile timestamps. Stable across
    /// the test run.
    static let fixedNow = Date()
}

// MARK: - Test helpers

/// One-shot async signal — a continuation that blocks the awaiter
/// until `release()` is called. Used to pin the fake's main Search in
/// flight while we provoke a generation-guard race.
final class AsyncSignal: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// `RecordingsDataSource` fake — drives the loader with scripted
/// responses, records call ordering for invariant assertions, and
/// signals completion of background tasks so tests can deterministically
/// wait for enrichment without arbitrary sleeps.
@MainActor
final class FakeRecordingsDataSource: RecordingsDataSource, @unchecked Sendable {
    struct SearchCall {
        let streamType: String
        let startedAt: TimeInterval
        let finishedAt: TimeInterval
    }

    var currentAIEventLog: [TimestampedAIEvent] = []
    var shouldConnect: Bool = true
    var recordSearchTimings: Bool = false

    var searchCalls: [SearchCall] = []
    private var mainResults: [RecordingsSearchOutcome] = []
    private var subResults: [RecordingsSearchOutcome] = []

    var mainSearchDelay: Duration = .zero
    var mainSearchGate: AsyncSignal?

    var alarmVideosForFindCall: [BaichuanAlarmVideoFile] = []
    var findAlarmVideosError: (any Error)?
    var eventsResult: RecordingsEventsOutcome = .unsupported

    private var subSearchSignal: AsyncSignal = AsyncSignal()
    private var alarmVideosSignal: AsyncSignal = AsyncSignal()
    private var eventsSignal: AsyncSignal = AsyncSignal()

    func queueMainResult(_ outcome: RecordingsSearchOutcome) {
        mainResults.append(outcome)
    }

    func queueSubResult(_ outcome: RecordingsSearchOutcome) {
        subResults.append(outcome)
        // A fresh queue means a fresh signal — the prior reload's signal
        // may already be released.
        subSearchSignal = AsyncSignal()
        alarmVideosSignal = AsyncSignal()
        eventsSignal = AsyncSignal()
    }

    func waitForSubSearch() async { await subSearchSignal.wait() }
    func waitForAlarmVideos() async { await alarmVideosSignal.wait() }
    func waitForEvents() async { await eventsSignal.wait() }

    func ensureConnectedBeforeFetch() async -> Bool {
        shouldConnect
    }

    func search(
        channel: Int,
        streamType: String,
        start: Date,
        end: Date,
        captureRaw: Bool
    ) async -> RecordingsSearchOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        if streamType == "main" {
            // Pop the queued outcome FIRST so each call binds its
            // result to its arrival order — otherwise the gated first
            // call and an ungated second call race for the same head
            // of the queue.
            let outcome = mainResults.isEmpty
                ? RecordingsSearchOutcome.failure("no main outcome queued")
                : mainResults.removeFirst()
            // Capture the gate by reference so a later `mainSearchGate
            // = nil` from the test doesn't affect this already-in-
            // flight call.
            let gate = mainSearchGate
            if mainSearchDelay > .zero {
                try? await Task.sleep(for: mainSearchDelay)
            }
            await gate?.wait()
            let finished = ProcessInfo.processInfo.systemUptime
            if recordSearchTimings {
                searchCalls.append(SearchCall(streamType: "main", startedAt: started, finishedAt: finished))
            }
            return outcome
        } else {
            let outcome = subResults.isEmpty
                ? RecordingsSearchOutcome.failure("no sub outcome queued")
                : subResults.removeFirst()
            let finished = ProcessInfo.processInfo.systemUptime
            if recordSearchTimings {
                searchCalls.append(SearchCall(streamType: "sub", startedAt: started, finishedAt: finished))
            }
            subSearchSignal.release()
            return outcome
        }
    }

    func findAlarmVideos(
        channel: Int,
        start: Date,
        end: Date,
        channelUID: String?
    ) async throws -> [BaichuanAlarmVideoFile] {
        defer { alarmVideosSignal.release() }
        if let findAlarmVideosError { throw findAlarmVideosError }
        return alarmVideosForFindCall
    }

    func getEvents(channel: Int, start: Date, end: Date) async -> RecordingsEventsOutcome {
        defer { eventsSignal.release() }
        return eventsResult
    }
}


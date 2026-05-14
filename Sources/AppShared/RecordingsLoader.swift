import Foundation
import OSLog
import ReolinkAPI
import ReolinkBaichuan

private let log = Logger(subsystem: "com.reolens.app", category: "recordings-loader")

/// 0.6.0 — `RecordingsLoader` owns the network orchestration + derived
/// state that used to live as 12 `@State` variables on each of the two
/// `RecordingsView` files (macOS 1,430 LOC and iOS 789 LOC, virtually
/// identical reload logic).
///
/// Responsibilities:
/// - Run the main → sub stream Search sequence, serialized to dodge
///   Home Hub Pro's `rcv failed` (-17) collision on concurrent Search
///   commands.
/// - Kick off the Baichuan `findAlarmVideo` and CGI `GetEvents`
///   enrichment passes in parallel once main has returned.
/// - Cancel stale reloads via a monotonically increasing generation
///   counter — rapid date flips never publish previous-day data on top
///   of the latest reload.
/// - Memoize `effectiveDetections(for:)` (the three-tier triggers →
///   Baichuan overlap → live aiEventLog fallback) by `SearchFile.id` so
///   the view doesn't re-walk the alarm-video list on every render.
///
/// Stays in the view: UI-only state — `aiFilter`, `nowPlaying`,
/// `showingBookmarks`, sheet/popover bindings. The view consumes
/// `loader.files` etc. via `@Observable` change notifications.
@MainActor
@Observable
public final class RecordingsLoader {
    // MARK: - Phases

    public enum LoadPhase: Sendable, Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    // MARK: - Inputs

    /// View-driven input. The view should bind this to its date
    /// picker, then call `reload()` from `.task(id: loader.selectedDate)`.
    /// Mutating this property alone does **not** trigger a reload —
    /// the explicit `reload()` keeps the contract simple and avoids
    /// racing detached `Task`s with the view's own task.
    public var selectedDate: Date

    // MARK: - Outputs

    public private(set) var files: [SearchFile] = []
    public private(set) var subFiles: [SearchFile] = []
    public private(set) var alarmVideoEntries: [BaichuanAlarmVideoFile] = []
    public private(set) var monthStatuses: [SearchStatus] = []
    public private(set) var eventLog: [HubEvent] = []
    public private(set) var eventsUnsupported: Bool = false
    public private(set) var alarmVideoLoading: Bool = false
    public private(set) var phase: LoadPhase = .idle
    public private(set) var lastRawResponse: String?

    /// True iff the view should display the spinner. The main Search
    /// drives this flag; once main resolves, the spinner clears and
    /// background enrichment (sub, GetEvents, findAlarmVideo) populates
    /// rows in-place.
    public var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    public var errorMessage: String? {
        if case .error(let message) = phase { return message }
        return nil
    }

    // MARK: - Dependencies

    private let source: any RecordingsDataSource
    private let channel: Int
    private let channelUID: String?
    private let captureRawResponses: Bool
    /// 0.6.0 — Identity used by cross-day ingestion. Optional so
    /// existing call sites can adopt the loader without simultaneously
    /// turning on the index; when nil the loader skips index writes.
    private let cameraID: UUID?
    private let cameraName: String
    private let index: RecordingIndex?

    // MARK: - Generation guard

    /// Bumped on every `reload()`. Background enrichment tasks compare
    /// their snapshot of `currentGeneration` to this value before
    /// publishing — a stale reload (rapid date flip) is dropped on the
    /// floor rather than overwriting the latest day's data.
    private var currentGeneration: Int = 0

    // MARK: - Memoization

    /// Per-file detection cache keyed by `SearchFile.id`. Invalidated
    /// whenever the inputs that feed `effectiveDetections(for:)` change
    /// (file list, alarm-video list, event log, or live aiEventLog).
    /// `fingerprint` makes the invalidation explicit instead of relying
    /// on identity comparisons that would miss in-place list mutation.
    private var detectionCache: [String: [DetectionType]] = [:]
    private var detectionCacheFingerprint: Int = 0

    // MARK: - Init

    public init(
        source: any RecordingsDataSource,
        channel: Int,
        channelUID: String? = nil,
        captureRawResponses: Bool = false,
        initialDate: Date = Date(),
        cameraID: UUID? = nil,
        cameraName: String = "",
        index: RecordingIndex? = nil
    ) {
        self.source = source
        self.channel = channel
        self.channelUID = channelUID
        self.captureRawResponses = captureRawResponses
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.index = index
        self.selectedDate = initialDate
    }

    // MARK: - Public API

    /// Trigger a fresh reload for `selectedDate`. Cancels any prior
    /// reload's published writes via the generation counter, then runs
    /// the canonical main → sub + parallel-enrichment sequence.
    public func reload() async {
        currentGeneration &+= 1
        let generation = currentGeneration

        phase = .loading
        // Don't clear `files` here — the view keeps showing the prior
        // day while we fetch, then atomically swaps when main returns.
        // Clearing would induce a flicker on every date flip.

        let connected = await source.ensureConnectedBeforeFetch()
        guard generation == currentGeneration else { return }
        guard connected else {
            publishError(
                "Camera isn't connected yet — try again once the live view is up.",
                generation: generation
            )
            return
        }

        guard let (start, end) = Self.searchWindow(for: selectedDate) else {
            publish(generation: generation) {
                self.files = []
                self.phase = .ready
            }
            return
        }

        // Main Search — user-blocking. Once this resolves, the row list
        // can render and we drop the loading flag. Enrichment continues
        // in the background and decorates rows in-place.
        let mainOutcome = await source.search(
            channel: channel,
            streamType: "main",
            start: start,
            end: end,
            captureRaw: captureRawResponses
        )
        guard generation == currentGeneration else { return }

        switch mainOutcome {
        case .success(let mainFiles, let raw, let statuses):
            let sortedFiles = mainFiles.sorted {
                ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
            publish(generation: generation) {
                self.lastRawResponse = raw
                self.files = sortedFiles
                if !statuses.isEmpty {
                    self.monthStatuses = statuses
                }
                // Sub & enrichment haven't fired yet — reset their
                // outputs so a date flip from a busy day to a quiet
                // day doesn't leave stale tags on rows.
                self.subFiles = []
                self.alarmVideoEntries = []
                if !self.eventsUnsupported {
                    self.eventLog = []
                }
                self.bumpDetectionFingerprint()
                self.phase = .ready
            }
            // 0.6.0 — Cross-day ingest. Fire-and-forget; the index is
            // an actor so writes are serialized internally. Skips when
            // `cameraID` wasn't supplied (call sites that haven't
            // opted in yet).
            ingestIntoIndex(sortedFiles, day: selectedDate)
        case .failure(let message):
            publishError(message, generation: generation)
            return
        }

        // Background enrichment — three parallel tasks. Each guards
        // its publication against the generation counter so a stale
        // reload never decorates the newer day's rows.
        Task { @MainActor [weak self] in
            await self?.loadSubStream(start: start, end: end, generation: generation)
        }
        Task { @MainActor [weak self] in
            await self?.loadEvents(start: start, end: end, generation: generation)
        }
        Task { @MainActor [weak self] in
            await self?.loadAlarmVideos(start: start, end: end, generation: generation)
        }
    }

    /// Cancel any in-flight reload by bumping the generation. Already-
    /// scheduled `Task`s will detect the mismatch and drop their writes.
    public func cancel() {
        currentGeneration &+= 1
    }

    /// Find the sub-stream `SearchFile` whose time range overlaps the
    /// most with `file`. Stream chunkers can emit ±2–6s offset segment
    /// boundaries, so equality matching fails; longest-overlap wins.
    public func subFileMatch(for file: SearchFile) -> SearchFile? {
        guard let mainStart = file.startDate, let mainEnd = file.endDate else { return nil }
        var best: (sub: SearchFile, overlap: TimeInterval)?
        for sub in subFiles {
            guard let subStart = sub.startDate, let subEnd = sub.endDate else { continue }
            let lo = max(mainStart, subStart)
            let hi = min(mainEnd, subEnd)
            let overlap = hi.timeIntervalSince(lo)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (sub, overlap)
            }
        }
        return best?.sub
    }

    /// Three-tier detection lookup, memoized by `SearchFile.id`.
    /// Order: `SearchFile.triggers` bitfield (when populated) →
    /// Baichuan `findAlarmVideo` entries overlapping the file's time
    /// range → live `aiEventLog` events overlapping → speculative
    /// CGI `GetEvents` probe response.
    public func effectiveDetections(for file: SearchFile) -> [DetectionType] {
        if let cached = detectionCache[file.id] { return cached }
        let computed = computeDetections(for: file)
        detectionCache[file.id] = computed
        return computed
    }

    /// 0.6.0 Slice 13b — `files` filtered by the supplied AI tag set.
    /// Empty filter returns all files. Centralized here so iOS +
    /// macOS shells stop duplicating the identical filter loop.
    public func filtered(by aiFilter: Set<DetectionType>) -> [SearchFile] {
        guard !aiFilter.isEmpty else { return files }
        return files.filter { file in
            let detections = Set(effectiveDetections(for: file))
            return !detections.isDisjoint(with: aiFilter)
        }
    }

    /// 0.6.0 Slice 13b — Live AI events from this session that fell
    /// on `selectedDate` for the loader's channel. Feeds the
    /// timeline strip's event-tick overlay. Reads through the data
    /// source's `currentAIEventLog` (production: `CameraSession.ai
    /// EventLog`; tests: a scripted array on the fake) so neither
    /// platform view has to thread `session.aiEventLog` separately.
    public func dayEvents() -> [TimestampedAIEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: selectedDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return source.currentAIEventLog.filter { ev in
            ev.channelID == channel
            && ev.timestamp >= startOfDay
            && ev.timestamp < endOfDay
        }
    }

    /// Returns every Baichuan alarm-video entry whose time range
    /// overlaps `file`. Falls back to filename match when timestamps
    /// are missing.
    public func alarmVideosOverlapping(_ file: SearchFile) -> [BaichuanAlarmVideoFile] {
        guard let fileStart = file.startDate, let fileEnd = file.endDate else {
            return alarmVideoEntries.filter { $0.fileName == file.name }
        }
        return alarmVideoEntries.filter { av in
            if av.fileName == file.name { return true }
            guard let avStart = av.startDate, let avEnd = av.endDate else { return false }
            return avStart < fileEnd && avEnd > fileStart
        }
    }

    // MARK: - Internals

    private func computeDetections(for file: SearchFile) -> [DetectionType] {
        if !file.triggers.isEmpty { return file.triggers }

        var matches: [DetectionType] = []
        var seen = Set<DetectionType>()

        for av in alarmVideosOverlapping(file) {
            for d in av.detections where seen.insert(d).inserted {
                matches.append(d)
            }
        }
        if !matches.isEmpty { return matches }

        guard let start = file.startDate, let end = file.endDate else { return [] }

        for event in source.currentAIEventLog
            where event.channelID == channel
                && event.timestamp >= start
                && event.timestamp <= end {
            if let d = event.detectionType, seen.insert(d).inserted {
                matches.append(d)
            }
        }
        for entry in eventLog where entry.overlaps(start: start, end: end) {
            for d in entry.detectionTypes where seen.insert(d).inserted {
                matches.append(d)
            }
        }
        return matches
    }

    private func loadSubStream(start: Date, end: Date, generation: Int) async {
        let outcome = await source.search(
            channel: channel,
            streamType: "sub",
            start: start,
            end: end,
            captureRaw: false
        )
        guard generation == currentGeneration else { return }
        switch outcome {
        case .success(let subResults, _, _):
            var seen = Set<String>()
            let unique = subResults.filter { seen.insert($0.name).inserted }
            publish(generation: generation) {
                self.subFiles = unique.sorted {
                    ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
                }
            }
            log.info("Sub-stream Search returned \(subResults.count) files")
        case .failure(let message):
            log.info("Sub-stream Search unavailable on channel \(self.channel): \(message, privacy: .public). Falling back to main-only.")
            publish(generation: generation) {
                self.subFiles = []
            }
        }
    }

    private func loadEvents(start: Date, end: Date, generation: Int) async {
        guard !eventsUnsupported else { return }
        let outcome = await source.getEvents(channel: channel, start: start, end: end)
        guard generation == currentGeneration else { return }
        switch outcome {
        case .events(let events):
            publish(generation: generation) {
                self.eventLog = events
                if events.isEmpty {
                    self.eventsUnsupported = true
                }
                self.bumpDetectionFingerprint()
            }
        case .unsupported:
            publish(generation: generation) {
                self.eventsUnsupported = true
                self.eventLog = []
            }
        case .failure(let error):
            log.debug("GetEvents probe failed: \(error.localizedDescription, privacy: .public)")
            publish(generation: generation) {
                self.eventsUnsupported = true
            }
        }
    }

    private func loadAlarmVideos(start: Date, end: Date, generation: Int) async {
        publish(generation: generation) { self.alarmVideoLoading = true }
        defer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publish(generation: generation) { self.alarmVideoLoading = false }
            }
        }

        do {
            let entries = try await source.findAlarmVideos(
                channel: channel,
                start: start,
                end: end,
                channelUID: channelUID
            )
            guard generation == currentGeneration else { return }
            publish(generation: generation) {
                self.alarmVideoEntries = entries
                self.bumpDetectionFingerprint()
            }
            // 0.6.0 — Enrich the cross-day index with the AI tags we
            // just got back.
            mergeAlarmVideosIntoIndex(entries, day: selectedDate)
        } catch {
            log.info("findAlarmVideos for channel \(self.channel) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingestIntoIndex(_ files: [SearchFile], day: Date) {
        guard let index, let cameraID else { return }
        let channel = channel
        let cameraName = cameraName
        Task {
            await index.ingest(
                files,
                cameraID: cameraID,
                cameraName: cameraName,
                channel: channel,
                day: day
            )
        }
    }

    private func mergeAlarmVideosIntoIndex(_ entries: [BaichuanAlarmVideoFile], day: Date) {
        guard let index, let cameraID else { return }
        let channel = channel
        Task {
            await index.mergeAlarmVideos(
                entries,
                cameraID: cameraID,
                channel: channel,
                day: day
            )
        }
    }

    private func publish(generation: Int, _ block: () -> Void) {
        guard generation == currentGeneration else { return }
        block()
    }

    private func publishError(_ message: String, generation: Int) {
        publish(generation: generation) {
            self.phase = .error(message)
            self.files = []
        }
    }

    /// Invalidate the per-file detection cache. Called whenever any of
    /// the inputs that feed `effectiveDetections(for:)` change. Cheap —
    /// O(1) — because we just bump the generation and drop the dict.
    private func bumpDetectionFingerprint() {
        detectionCacheFingerprint &+= 1
        detectionCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Time bounds

    /// Day-aligned `[start, end-of-day-or-now]` window matching the
    /// existing iOS/macOS view behavior. Returns nil for future days,
    /// which the view treats as "no recordings".
    public static func searchWindow(for day: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: start)?
            .addingTimeInterval(-1) else { return nil }
        let now = Date()
        guard start <= now else { return nil }
        return (start, min(endOfDay, now))
    }
}

// MARK: - Data source protocol

/// Abstraction over the live `CameraSession` so `RecordingsLoader` can
/// be exercised by unit tests without spinning a real Reolink client.
/// Production conformance lives in `CameraSession+RecordingsLoader.swift`.
public protocol RecordingsDataSource: AnyObject, Sendable {
    /// Snapshot of the session's live AI event log at the moment this
    /// is read. Used by the three-tier detection fallback. Read on the
    /// main actor by the loader.
    @MainActor var currentAIEventLog: [TimestampedAIEvent] { get }

    /// Wait briefly for the underlying session to be connected before
    /// firing the Search command, mirroring the existing pre-flight
    /// check. Returns false if the session is still not connected when
    /// the budget expires.
    @MainActor func ensureConnectedBeforeFetch() async -> Bool

    /// CGI `Search` for one (channel, streamType) over `[start, end]`.
    /// Live conformances should wrap this in their background-polling-
    /// pause primitive so the user-initiated Search isn't queued
    /// behind motion-state pollers on busy hubs.
    @MainActor func search(
        channel: Int,
        streamType: String,
        start: Date,
        end: Date,
        captureRaw: Bool
    ) async -> RecordingsSearchOutcome

    /// Baichuan `findAlarmVideo` lookup. Implementations route via the
    /// channel's per-camera UID when available — the loader passes it
    /// through from `channelUID`.
    @MainActor func findAlarmVideos(
        channel: Int,
        start: Date,
        end: Date,
        channelUID: String?
    ) async throws -> [BaichuanAlarmVideoFile]

    /// Speculative CGI `GetEvents` probe. Returns `.unsupported` when
    /// the firmware doesn't carry a historical event list so the
    /// loader can stop retrying for the rest of the session.
    @MainActor func getEvents(
        channel: Int,
        start: Date,
        end: Date
    ) async -> RecordingsEventsOutcome
}

/// Result of a single CGI `Search` request. Carries the parsed file
/// list, the parsed month-status bitfield, and an optional pretty-
/// printed raw response (only when `captureRaw` is set).
public enum RecordingsSearchOutcome: Sendable {
    case success([SearchFile], rawPretty: String, statuses: [SearchStatus])
    case failure(String)
}

/// Result of a CGI `GetEvents` probe. Three-state because the
/// "firmware doesn't support GetEvents" case is sticky for the rest of
/// the session and the loader needs to remember it.
public enum RecordingsEventsOutcome: Sendable {
    case events([HubEvent])
    case unsupported
    case failure(any Error)
}

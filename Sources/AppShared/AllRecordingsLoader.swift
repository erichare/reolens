import Foundation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.app", category: "all-recordings")

/// 0.5.1 — A `SearchFile` decorated with its source camera so the All
/// Recordings view can display the camera name alongside each row.
public struct ScopedRecording: Identifiable, Sendable, Hashable {
    public let file: SearchFile
    public let cameraKey: CameraFilterBar.CameraChannelKey

    /// Composite ID — `SearchFile.name` is only unique within a single
    /// channel. Different channels can share the same filename for the
    /// same minute of recording, so we need to namespace it.
    public var id: String { "\(cameraKey.channel):\(file.id)" }

    public init(file: SearchFile, cameraKey: CameraFilterBar.CameraChannelKey) {
        self.file = file
        self.cameraKey = cameraKey
    }
}

/// 0.5.1 — All Recordings loader. Fans out `Commands.search` across
/// (hub, channel) pairs in parallel (bounded so large NVRs and
/// multi-hub setups don't slam the network), merges into one sorted
/// feed, and returns the result. Per-(hub, channel) errors surface
/// as warnings — one bad channel doesn't fail the whole view.
///
/// Bounded concurrency is important because Home Hub Pro caps
/// concurrent CGI requests per device; widening the cap to 6 across
/// all hubs gives multi-hub users reasonable parallelism without
/// any one hub ever seeing more than ~4 in-flight calls.
public enum AllRecordingsLoader {
    /// Global cap across all hubs. Each hub still self-throttles via
    /// its own session-level concurrency primitives.
    public static let maxConcurrentChannels = 6

    /// 0.5.1 — A (session, camera) pair queued for fan-out fetch.
    /// Public so call sites can build the work list directly (most
    /// commonly: every channel under every session in `CameraStore`).
    public struct ChannelTask: Sendable {
        public let session: CameraSession
        public let camera: CameraFilterBar.CameraChannelKey

        public init(session: CameraSession, camera: CameraFilterBar.CameraChannelKey) {
            self.session = session
            self.camera = camera
        }
    }

    /// Hub-scoped convenience overload (backwards compatible). Builds a
    /// list of `ChannelTask`s from one session's `cameras`.
    public static func load(
        session: CameraSession,
        cameras: [CameraFilterBar.CameraChannelKey],
        day: Date
    ) async -> [ScopedRecording] {
        let tasks = cameras.map { ChannelTask(session: session, camera: $0) }
        return await load(tasks: tasks, day: day)
    }

    /// Cross-hub variant. Each `ChannelTask` carries its own session,
    /// so the loader can fan out across multiple Reolink accounts /
    /// hubs without needing a single shared client.
    public static func load(
        tasks: [ChannelTask],
        day: Date
    ) async -> [ScopedRecording] {
        var merged: [ScopedRecording] = []
        for await batch in loadStreaming(tasks: tasks, day: day) {
            merged.append(contentsOf: batch)
        }
        merged.sort { lhs, rhs in
            (lhs.file.startDate ?? .distantPast) > (rhs.file.startDate ?? .distantPast)
        }
        return merged
    }

    /// 0.5.1 — Streaming variant. Yields a `[ScopedRecording]` batch
    /// as each (session, channel) fetch resolves so the UI can paint
    /// rows progressively instead of blocking on the slowest channel.
    /// Each batch is unsorted relative to others; consumers sort on
    /// insert.
    public static func loadStreaming(
        tasks: [ChannelTask],
        day: Date
    ) -> AsyncStream<[ScopedRecording]> {
        AsyncStream { continuation in
            let task = Task {
                guard !tasks.isEmpty else {
                    continuation.finish()
                    return
                }
                let (start, end) = dayBounds(for: day)
                await withTaskGroup(of: [ScopedRecording].self) { group in
                    var iterator = tasks.makeIterator()
                    var inFlight = 0
                    while inFlight < maxConcurrentChannels, let next = iterator.next() {
                        group.addTask {
                            await fetch(client: next.session.client, camera: next.camera, start: start, end: end)
                        }
                        inFlight += 1
                    }
                    while let batch = await group.next() {
                        continuation.yield(batch)
                        if let next = iterator.next() {
                            group.addTask {
                                await fetch(client: next.session.client, camera: next.camera, start: start, end: end)
                            }
                        } else {
                            inFlight -= 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fetch(
        client: CGIClient,
        camera: CameraFilterBar.CameraChannelKey,
        start: Date,
        end: Date
    ) async -> [ScopedRecording] {
        let cmd = Commands.search(
            channel: camera.channel,
            onlyStatus: false,
            streamType: "main",
            start: start,
            end: end
        )
        do {
            let envelope = try await client.send(cmd, as: SearchEnvelope.self)
            let files = envelope.SearchResult.File ?? []
            return files.map { ScopedRecording(file: $0, cameraKey: camera) }
        } catch {
            log.warning("All Recordings: channel \(camera.channel) failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func dayBounds(for day: Date) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }
}

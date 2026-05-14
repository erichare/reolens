import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "preview-prefetch")

/// 0.5.1 — Background snapshot prefetcher. The user reported that
/// cameras with no cached preview render a "No preview yet"
/// placeholder until they're actually opened. This actor sweeps
/// every configured channel periodically (and once on launch) and
/// fetches a `cmd=Snap` JPEG for any channel whose cache is missing
/// or stale, so the first time the user surfaces a tile it already
/// has something visible.
///
/// Design constraints:
/// - **Bounded concurrency.** A Home Hub Pro caps concurrent CGI
///   requests; a TaskGroup limited to 3 in flight keeps it polite.
/// - **Battery-camera safe.** Battery / asleep channels are skipped
///   — waking a battery camera every 15 min just to refresh a still
///   would burn battery for a feature users rarely look at. They
///   still get a fresh snapshot when actually viewed (the existing
///   `prepareForFetch` wake path on `CameraPreviewImage`).
/// - **Idempotent + cancel-safe.** `start(store:)` is a no-op when
///   already running; `stop()` cancels any in-flight sweep so a
///   background-to-foreground transition doesn't double up.
/// - **Honors live-grid mode.** When the user has flipped the grid
///   to always-live (Settings → General → "Live previews in grid")
///   the tiles already stream — no need to prefetch JPEGs in the
///   background. We still run on app activation to seed cold-tile
///   cases.
@MainActor
public final class CameraPreviewPrefetcher {
    public static let shared = CameraPreviewPrefetcher()

    /// Cache freshness threshold. Snapshots older than this get
    /// refreshed on the next sweep. 10 minutes balances "preview
    /// looks current" against polling load on the hub.
    public static let staleThreshold: TimeInterval = 10 * 60
    /// Periodic sweep interval. 15 min keeps stale tiles fresh
    /// without making the hub feel constantly polled.
    public static let cycleInterval: TimeInterval = 15 * 60
    /// Max in-flight snapshot fetches across all hubs at once.
    public static let maxConcurrent = 3

    private var loop: Task<Void, Never>?
    private weak var store: CameraStore?
    /// 0.6.0 TD-3b — `ProcessInfo` lookup is hoisted into a closure
    /// so tests can inject a fixed answer. Production reads the live
    /// system flag (Low Power Mode on iOS, the equivalent thermal
    /// state on macOS). Returning true short-circuits each sweep —
    /// the next `.active` transition is when the user expects fresh
    /// tiles, so the periodic cycle is what we drop.
    public var isLowPowerModeProbe: @MainActor () -> Bool = {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    /// Sweep that was skipped because of low-power mode — recorded
    /// so observers can surface "deferred until power returns" in
    /// diagnostics. Counter rather than a bool because nested calls
    /// during a long Low Power session add up.
    public private(set) var skippedSweepCount: Int = 0

    public init() {}

    /// Start the periodic sweep. Idempotent — calling twice does not
    /// start a second loop. Pass the live `CameraStore` so the loop
    /// can discover newly-added cameras without restart.
    public func start(store: CameraStore) {
        self.store = store
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Initial sweep happens immediately so the user gets
            // tiles populated within seconds of opening the app.
            await self?.sweepNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.cycleInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.sweepNow()
            }
        }
    }

    /// Cancel any in-flight sweep + stop the periodic loop. Called
    /// on `scenePhase != .active` so background ticks don't run.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Force a single sweep right now (e.g. on scene activation, or
    /// after the user adds a new camera). Concurrent calls are
    /// deduplicated by the underlying `CameraPreviewService` actor.
    public func sweepNow() async {
        guard let store else { return }
        // 0.6.0 TD-3b — short-circuit when the device is in Low
        // Power Mode. The user has explicitly asked iOS / macOS to
        // minimize background work; firing CGI snapshot fetches on
        // a 15-minute cadence violates that contract. We DO still
        // refresh when the user actively opens a tile (the
        // `CameraPreviewImage` on-appear refresh path is separate
        // from this prefetcher).
        if isLowPowerModeProbe() {
            skippedSweepCount &+= 1
            log.info("Prefetch sweep skipped — Low Power Mode (skip count: \(self.skippedSweepCount, privacy: .public))")
            return
        }
        let work = collectWork(store: store)
        guard !work.isEmpty else { return }
        log.info("Prefetch sweep: \(work.count, privacy: .public) channels")
        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            var inFlight = 0
            while inFlight < Self.maxConcurrent, let item = iterator.next() {
                group.addTask { await Self.fetch(item) }
                inFlight += 1
            }
            while await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask { await Self.fetch(item) }
                } else {
                    inFlight -= 1
                }
            }
        }
    }

    // MARK: - Internal

    private struct WorkItem: Sendable {
        let session: CameraSession
        let cameraID: UUID
        let channel: Int
    }

    private func collectWork(store: CameraStore) -> [WorkItem] {
        var items: [WorkItem] = []
        for session in store.sessions.values {
            guard session.status == .connected else { continue }
            for channel in session.liveChannels {
                // Battery-camera carve-out: see header comment. Wake
                // path is reserved for explicit user interaction.
                if session.isBatteryPoweredOrAsleep(channel: channel.channel) {
                    continue
                }
                // Only fetch when the cache is missing or stale —
                // `CameraPreviewImage` will refresh on appear for
                // anything within the threshold, so re-fetching is
                // wasteful.
                let cachedAt = CameraPreviewService.shared.cachedAt(
                    cameraID: session.entry.id,
                    channel: channel.channel
                )
                let needsRefresh: Bool = {
                    guard let cachedAt else { return true }
                    return Date().timeIntervalSince(cachedAt) > Self.staleThreshold
                }()
                guard needsRefresh else { continue }
                items.append(WorkItem(
                    session: session,
                    cameraID: session.entry.id,
                    channel: channel.channel
                ))
            }
        }
        return items
    }

    private static func fetch(_ item: WorkItem) async {
        let snapURL = await item.session.snapshotURL(channel: item.channel)
        guard let snapURL else { return }
        let cameraName = await MainActor.run { item.session.entry.displayName }
        let bytes = await CameraPreviewService.shared.refresh(
            snapshotURL: snapURL,
            cameraID: item.cameraID,
            channel: item.channel
        )
        guard let bytes else { return }
        // Publish into the shared App-Group container so widgets
        // pick up the freshly-prefetched snapshot on their next
        // timeline reload. AGENTS.md §16 — extensions read, main
        // app writes.
        await CameraPreviewService.publishToSharedContainer(
            data: bytes,
            cameraID: item.cameraID,
            channel: item.channel,
            cameraName: cameraName
        )
    }
}

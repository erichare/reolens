import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "poll-manager")

/// 0.6.0 Slice 14 — generic, testable polling lifecycle.
///
/// `CameraSession` previously owned three intertwined responsibilities
/// for motion-event polling: a `pollTask` handle, an `initialDelay +
/// repeating loop with adaptive interval`, and a depth-counted "pause
/// while a user-initiated CGI op is in flight" gate. `PollManager`
/// extracts those into a single class so:
///
/// 1. The polling state machine is unit-testable in isolation (the
///    session-level test was reduced to "things compile"). A
///    `withBackgroundPollingPaused` regression that re-paused without
///    decrementing the depth is now expressible as a `@Test` case.
/// 2. Future surfaces (`RecordingIndex` background-refill,
///    capability-probe polling) can reuse the same lifecycle without
///    duplicating the cancel/restart machinery.
/// 3. The session itself stays focused on connection lifecycle and
///    state aggregation — about 30 LOC lighter post-extraction.
///
/// **Pause/resume is depth-counted**: nested calls to
/// `pausingBackgroundPolling(_:)` only resume the inner work when the
/// outermost call returns. The previous inline implementation in
/// CameraSession had the same shape; this preserves it.
@MainActor
@Observable
public final class PollManager {

    /// One iteration of the polling loop. Invoked from a `Task` that
    /// the manager owns, on the main actor. Implementor performs its
    /// per-tick work; the manager schedules the next tick after the
    /// configured interval. Cooperatively cancellable: implementors
    /// should check `Task.isCancelled` between sub-requests.
    public typealias Work = @MainActor () async -> Void

    /// Interval lookup. Re-evaluated each iteration so phase changes
    /// (foreground ↔ background ↔ low-power) take effect on the next
    /// sleep, never mid-tick.
    public typealias IntervalProvider = @MainActor () -> TimeInterval

    /// True while the polling loop is active (a `Task` is running
    /// either the initial-delay sleep or the per-tick loop). Goes
    /// false when paused, stopped, or the task completes its `while`
    /// condition.
    public private(set) var isRunning: Bool = false

    /// Pause depth. Zero = polling is allowed to run; positive =
    /// suspended. Stored so the public `pauseDepth` is observable for
    /// debugging.
    public private(set) var pauseDepth: Int = 0

    private var task: Task<Void, Never>?
    /// True when a pause was applied to an already-running task and we
    /// should restart polling once the outermost resume happens. False
    /// when paused but polling wasn't running anyway (e.g. session was
    /// never connected) so resume becomes a no-op.
    private var resumeOnLastPop: Bool = false

    private let initialDelay: TimeInterval
    private let intervalProvider: IntervalProvider
    private let work: Work
    /// Runtime gate. Called before each tick to decide whether the
    /// loop should still be alive. Returning false ends the loop;
    /// typical implementation reads `session.status == .connected`.
    private let shouldContinue: @MainActor () -> Bool

    public init(
        initialDelay: TimeInterval,
        intervalProvider: @escaping IntervalProvider,
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        work: @escaping Work
    ) {
        self.initialDelay = initialDelay
        self.intervalProvider = intervalProvider
        self.shouldContinue = shouldContinue
        self.work = work
    }

    /// Begin polling. Cancels any prior task. Has no effect while
    /// paused — the caller must drop the pause depth back to zero
    /// before the loop actually starts. This mirrors the previous
    /// behaviour where `startEventPolling()` could be safely called
    /// even when paused.
    public func start() {
        task?.cancel()
        guard pauseDepth == 0 else {
            // Mark that the caller wants polling to be running so a
            // later resume restarts it.
            resumeOnLastPop = true
            isRunning = false
            return
        }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.initialDelay ?? 0))
            while let self, !Task.isCancelled, self.shouldContinue() {
                await self.work()
                let interval = self.intervalProvider()
                try? await Task.sleep(for: .seconds(interval))
            }
            // Loop ended (cancelled / shouldContinue went false).
            // Reflect the new state for observers.
            self?.isRunning = false
        }
        isRunning = true
        resumeOnLastPop = false
    }

    /// Halt polling unconditionally. After this returns, `isRunning`
    /// is false; no further `work()` invocations happen unless `start`
    /// is called again.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        resumeOnLastPop = false
        pauseDepth = 0
    }

    /// Run `body` with polling paused. Nested calls are safe —
    /// polling only resumes when the outermost call returns. Mirrors
    /// the `CameraSession.withBackgroundPollingPaused` semantic; named
    /// differently here to avoid the recursive overload conflict that
    /// extension-conformance hit in Slice 10.
    public func pausingBackgroundPolling<T: Sendable>(
        _ body: @MainActor () async -> T
    ) async -> T {
        pushPause()
        defer { popPause() }
        return await body()
    }

    /// Throwing overload — propagates the body's error after the pause
    /// depth has been popped.
    public func pausingBackgroundPolling<T: Sendable>(
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        pushPause()
        defer { popPause() }
        return try await body()
    }

    // MARK: - Internals

    private func pushPause() {
        if pauseDepth == 0 {
            // First pause level — cancel the running task if any, and
            // remember whether we need to restart on resume.
            resumeOnLastPop = isRunning
            task?.cancel()
            task = nil
            isRunning = false
        }
        pauseDepth += 1
    }

    private func popPause() {
        guard pauseDepth > 0 else { return }
        pauseDepth -= 1
        if pauseDepth == 0, resumeOnLastPop {
            // Only restart if we were running before the outermost
            // pause. `start()` is reentrant — safe to call here.
            resumeOnLastPop = false
            start()
        }
    }
}

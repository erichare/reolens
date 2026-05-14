import Testing
import Foundation
@testable import AppShared

/// 0.6.0 Slice 14 — `PollManager` is the lifecycle the CameraSession
/// previously held inline. Tests pin its contract:
///
/// - `start()` runs the initial-delay sleep, then ticks at the
///   interval-provider's rate.
/// - `stop()` cancels in-flight ticks and clears the depth.
/// - `pausingBackgroundPolling(_:)` is depth-counted: nested calls
///   only resume when the outermost call returns.
/// - Resume after pause only happens when polling was previously
///   running (start-while-paused doesn't accidentally start the loop
///   on resume).
/// - `shouldContinue` returning false ends the loop.
@MainActor
@Suite("PollManager")
struct PollManagerTests {

    // MARK: - Test helpers

    /// Build a manager whose work bumps a counter and whose interval
    /// is short enough that several ticks happen during a test wait
    /// without making the suite slow.
    private func makeFastTickManager(
        initialDelay: TimeInterval = 0,
        intervalSeconds: TimeInterval = 0.02,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) -> (manager: PollManager, count: Counter) {
        let counter = Counter()
        let manager = PollManager(
            initialDelay: initialDelay,
            intervalProvider: { intervalSeconds },
            shouldContinue: shouldContinue,
            work: { @MainActor in counter.increment() }
        )
        return (manager, counter)
    }

    /// Spin-wait until `condition` returns true or `timeoutSeconds`
    /// elapses. Used instead of arbitrary sleeps so flake-prone tests
    /// can be deterministic.
    private func waitUntil(
        timeoutSeconds: TimeInterval = 1.0,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Start / stop

    @Test("start() runs the work block at least once, then keeps ticking")
    func startTicks() async {
        let (manager, counter) = makeFastTickManager()
        manager.start()
        #expect(manager.isRunning)
        await waitUntil { counter.value >= 3 }
        #expect(counter.value >= 3)
        manager.stop()
    }

    @Test("stop() halts the loop and clears isRunning")
    func stopHalts() async {
        let (manager, counter) = makeFastTickManager()
        manager.start()
        await waitUntil { counter.value >= 1 }
        manager.stop()
        let observed = counter.value
        try? await Task.sleep(for: .milliseconds(50))
        // Counter shouldn't keep climbing after stop.
        #expect(counter.value <= observed + 1)
        #expect(!manager.isRunning)
        #expect(manager.pauseDepth == 0)
    }

    @Test("shouldContinue returning false ends the loop without explicit stop")
    func shouldContinueGate() async {
        let counter = Counter()
        let gate = Gate(value: true)
        let manager = PollManager(
            initialDelay: 0,
            intervalProvider: { 0.02 },
            shouldContinue: { @MainActor in gate.value },
            work: { @MainActor in counter.increment() }
        )
        manager.start()
        await waitUntil { counter.value >= 2 }
        gate.value = false
        // Wait a beat for the next sleep to elapse and the loop to
        // exit on the next iteration's `shouldContinue` check.
        await waitUntil { !manager.isRunning }
        #expect(!manager.isRunning)
    }

    // MARK: - Pause / resume

    @Test("pausingBackgroundPolling(_:) suspends polling for the body's lifetime")
    func pauseStopsTicks() async {
        let (manager, counter) = makeFastTickManager()
        manager.start()
        await waitUntil { counter.value >= 1 }

        await manager.pausingBackgroundPolling {
            let observed = counter.value
            try? await Task.sleep(for: .milliseconds(100))
            // No new ticks during the pause body.
            #expect(counter.value == observed)
        }

        // Polling resumed automatically after the pause body returned.
        await waitUntil { manager.isRunning }
        #expect(manager.isRunning)
        manager.stop()
    }

    @Test("Nested pauses only resume when the outermost body returns")
    func nestedPause() async {
        let (manager, counter) = makeFastTickManager()
        manager.start()
        await waitUntil { counter.value >= 1 }

        await manager.pausingBackgroundPolling {
            #expect(manager.pauseDepth == 1)
            #expect(!manager.isRunning)
            await manager.pausingBackgroundPolling {
                #expect(manager.pauseDepth == 2)
                #expect(!manager.isRunning)
            }
            // Outer body still active — still paused.
            #expect(manager.pauseDepth == 1)
            #expect(!manager.isRunning)
        }
        // Outermost pop — polling resumes.
        #expect(manager.pauseDepth == 0)
        await waitUntil { manager.isRunning }
        manager.stop()
    }

    @Test("Pause without prior start doesn't trigger spurious resume")
    func pauseFromIdleIsAResume() async {
        let (manager, counter) = makeFastTickManager()
        // Never call start.
        await manager.pausingBackgroundPolling {
            // No-op body.
        }
        // The manager should still be idle — not running, no ticks
        // happened.
        #expect(!manager.isRunning)
        #expect(counter.value == 0)
        // A pop from depth 1 → 0 shouldn't have triggered start().
        manager.stop()
    }

    @Test("Throwing pause body propagates the error and still pops the depth")
    func pauseThrowingBody() async {
        let (manager, _) = makeFastTickManager()
        manager.start()
        struct Boom: Error {}

        do {
            try await manager.pausingBackgroundPolling { () throws in
                throw Boom()
            }
            Issue.record("Expected the body to throw")
        } catch is Boom {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(manager.pauseDepth == 0)
        manager.stop()
    }
}

// MARK: - Test-only helpers

/// Counter mutated from MainActor closures. Reference type so each
/// `increment()` is visible to the test code reading `.value`.
@MainActor
final class Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Mutable flag used by `shouldContinue` to end the loop mid-test.
@MainActor
final class Gate {
    var value: Bool
    init(value: Bool) { self.value = value }
}

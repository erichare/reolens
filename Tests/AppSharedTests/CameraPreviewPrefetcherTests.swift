import Testing
import Foundation
@testable import AppShared

/// 0.6.0 TD-3b — `CameraPreviewPrefetcher`'s observable surface
/// (low-power short-circuit, skip counter) is testable in isolation
/// because the work itself is gated behind a probe closure that
/// tests can inject. Tests pin:
///
/// - Sweep short-circuits when the probe says Low Power Mode is on.
/// - The skip counter monotonically increments per skipped sweep.
/// - Sweep is a no-op when no store has been attached.
@MainActor
@Suite("CameraPreviewPrefetcher — low-power gate")
struct CameraPreviewPrefetcherTests {

    @Test("sweepNow no-ops when no store is attached")
    func sweepWithoutStore() async {
        let prefetcher = CameraPreviewPrefetcher()
        // No `start(store:)` call — `sweepNow` should bail without
        // consulting the low-power probe.
        await prefetcher.sweepNow()
        #expect(prefetcher.skippedSweepCount == 0)
    }

    @Test("Low-power probe returning true short-circuits the sweep and increments skip counter")
    func sweepSkippedInLowPowerMode() async {
        let prefetcher = CameraPreviewPrefetcher()
        let store = CameraStore()
        prefetcher.isLowPowerModeProbe = { true }
        prefetcher.start(store: store)
        await prefetcher.sweepNow()
        #expect(prefetcher.skippedSweepCount == 1)
        await prefetcher.sweepNow()
        #expect(prefetcher.skippedSweepCount == 2)
        prefetcher.stop()
    }

    @Test("Low-power probe returning false lets sweepNow proceed past the gate")
    func sweepProceedsOutOfLowPowerMode() async {
        let prefetcher = CameraPreviewPrefetcher()
        let store = CameraStore()
        prefetcher.isLowPowerModeProbe = { false }
        prefetcher.start(store: store)
        // With no cameras configured the sweep finds zero work and
        // returns early without touching the network — that's the
        // path under test. The important assertion is that we did
        // NOT bump the skip counter.
        await prefetcher.sweepNow()
        #expect(prefetcher.skippedSweepCount == 0)
        prefetcher.stop()
    }

    @Test("stop() leaves the skip counter intact for diagnostic readback")
    func stopPreservesSkipCounter() async {
        let prefetcher = CameraPreviewPrefetcher()
        let store = CameraStore()
        prefetcher.isLowPowerModeProbe = { true }
        prefetcher.start(store: store)
        await prefetcher.sweepNow()
        let observedBeforeStop = prefetcher.skippedSweepCount
        prefetcher.stop()
        // Counter is metadata for diagnostics — should survive a stop.
        #expect(prefetcher.skippedSweepCount == observedBeforeStop)
    }
}

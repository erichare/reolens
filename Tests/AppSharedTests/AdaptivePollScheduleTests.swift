import Testing
import Foundation
@testable import AppShared

/// Tests for `AdaptivePollSchedule.intervalSeconds(for:)`. The pure
/// table-mapping function so the interval contract is locked in
/// without depending on the runtime singleton.
@Suite("AdaptivePollSchedule intervals")
struct AdaptivePollScheduleTests {

    @Test("Foreground intent maps to 10 s")
    func foregroundIs10s() {
        #expect(AdaptivePollSchedule.intervalSeconds(for: .foreground) == 10)
    }

    @Test("Background intent maps to 60 s")
    func backgroundIs60s() {
        #expect(AdaptivePollSchedule.intervalSeconds(for: .background) == 60)
    }

    @Test("Low-power intent maps to 120 s")
    func lowPowerIs120s() {
        #expect(AdaptivePollSchedule.intervalSeconds(for: .lowPower) == 120)
    }

    @Test("Each intent yields a distinct, monotonically increasing interval")
    func monotonicOrder() {
        let foreground = AdaptivePollSchedule.intervalSeconds(for: .foreground)
        let background = AdaptivePollSchedule.intervalSeconds(for: .background)
        let lowPower = AdaptivePollSchedule.intervalSeconds(for: .lowPower)
        #expect(foreground < background)
        #expect(background < lowPower)
    }
}

import Testing
import Foundation
@testable import AppShared

/// Tests for `CameraNotificationHealth.formatBadge` — pure-function
/// boundary cases so the sidebar badge renders the right token at every
/// time-since-last-event range. The instance-side refresh path depends
/// on the App Group `SharedContainer` which isn't available under
/// `swift test`, so we cover it via a smaller helper that operates on
/// an injected event list.
@Suite("CameraNotificationHealth.formatBadge")
struct CameraNotificationHealthFormatBadgeTests {

    @Test("Negative or sub-minute intervals format as 'now'")
    func subMinuteIsNow() {
        #expect(CameraNotificationHealth.formatBadge(timeAgo: -5) == "now")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 0) == "now")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 59) == "now")
    }

    @Test("Minute granularity for intervals 1 m – 59 m")
    func minuteRange() {
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 60) == "1m")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 12 * 60) == "12m")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 59 * 60 + 30) == "59m")
    }

    @Test("Hour granularity for intervals 1 h – 23 h")
    func hourRange() {
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 3600) == "1h")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 3 * 3600) == "3h")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 23 * 3600 + 1800) == "23h")
    }

    @Test("Day granularity for intervals 1 d – 6 d")
    func dayRange() {
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 86_400) == "1d")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 3 * 86_400) == "3d")
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 6 * 86_400 + 3600) == "6d")
    }

    @Test("Older than a week returns nil so the badge hides")
    func stalerReturnsNil() {
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 7 * 86_400) == nil)
        #expect(CameraNotificationHealth.formatBadge(timeAgo: 30 * 86_400) == nil)
    }
}

import Foundation
import UserNotifications
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "digest-scheduler")

/// 0.5.0 Theme A5 — daily-fire scheduler that wakes the app at the
/// user-configured digest time (default 07:00 local), assembles a
/// `DailyDigestRecord` from yesterday's events in the App-Group
/// `RecentMotionEvents.plist`, writes it to
/// `<AppGroup>/digests/<yyyy-MM-dd>.json`, and posts a local
/// `UNNotificationRequest` whose tap deep-links into
/// `DigestDetailView`.
///
/// Uses `UNCalendarNotificationTrigger` for the fire — survives
/// app death without a background mode, fires whether or not the
/// user has the app in the foreground.
///
/// Idempotency: the digest record for a given local day is written
/// at most once. If the scheduler fires twice on the same day (rare
/// — clock change, time-zone shift, manual "run now"), the second
/// write overwrites with the latest event roll-up; downstream
/// readers just see the freshest version.
public actor DigestScheduler {

    public static let shared = DigestScheduler()

    /// Notification category — the system pairs the tap-handling
    /// routine in `NotificationTapDelegate` with this string.
    public static let notificationCategory = "reolens.digest"
    public static let userInfoDigestDayKey = "digestDay"
    public static let scheduledRequestID = "com.reolens.overnightDigest.daily"

    private init() {}

    /// Reconcile the scheduled local notification with the user's
    /// current settings. Call this:
    ///   * on app launch
    ///   * after the user toggles `digestEnabled` or
    ///     changes `digestHourOfDay`
    ///   * after a digest fires (so the trigger re-registers for
    ///     the next day — `.repeats: true` does this for us, but
    ///     we re-register defensively in case the hour changed
    ///     mid-cycle)
    public func reconcileSchedule() async {
        let settings = OvernightDigestSettings()
        if !settings.enabled {
            await cancelScheduledNotification()
            return
        }
        await scheduleDailyNotification(hour: settings.hourOfDay)
    }

    /// Run the digest pipeline NOW for `referenceDate` (the moment the
    /// scheduler fired). Pulls events from the App-Group container
    /// covering the previous local-midnight → reference window,
    /// writes the digest, posts the notification.
    ///
    /// Public so the iOS notification handler (a `UNNotificationServiceExtension`
    /// or — for now — the foreground app's `NotificationTapDelegate`)
    /// can invoke it without going through the scheduler's actor
    /// state. Idempotent: re-running for the same `day` overwrites.
    public func runDigest(now referenceDate: Date = Date(), calendar: Calendar = .autoupdatingCurrent) async {
        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            log.error("Couldn't compute yesterday for digest fire")
            return
        }

        let recent = SharedContainer.readRecentMotionEvents()
        let inputs: [DigestBuilder.InputEvent] = recent.compactMap { record in
            guard record.timestamp >= yesterdayStart, record.timestamp < todayStart else { return nil }
            let detection = record.aiTags.first ?? "motion"
            return DigestBuilder.InputEvent(
                cameraID: record.cameraID,
                cameraName: record.cameraName,
                detection: detection,
                timestamp: record.timestamp
            )
        }

        let digest = DigestBuilder.build(day: yesterdayStart, events: inputs, calendar: calendar)
        do {
            try SharedContainer.writeDailyDigest(digest)
            #if canImport(WidgetKit)
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
            }
            #endif
            log.info("Digest written: day=\(yesterdayStart, privacy: .public) total=\(digest.totalEvents) cameras=\(digest.perCameraCounts.count)")
            await postDigestNotification(digest: digest)
        } catch {
            log.error("Couldn't write digest: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Scheduling

    private func scheduleDailyNotification(hour: Int) async {
        let center = UNUserNotificationCenter.current()
        await cancelScheduledNotification()

        // Register the digest notification category once. Tap
        // handling routes through `NotificationTapDelegate` —
        // see `EventNotifier.swift`.
        let category = UNNotificationCategory(
            identifier: Self.notificationCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        // Keep existing categories intact — fetch + union rather
        // than replace.
        let existing = await center.notificationCategories()
        center.setNotificationCategories(existing.union([category]))

        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "Overnight digest"
        content.body = "Tap to see what your cameras caught overnight."
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [Self.userInfoDigestDayKey: Date().timeIntervalSince1970]

        let request = UNNotificationRequest(
            identifier: Self.scheduledRequestID,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            log.info("Digest scheduled daily at \(hour):00 local")
        } catch {
            log.warning("Couldn't schedule digest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelScheduledNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.scheduledRequestID])
    }

    /// Post a one-shot notification immediately after building the
    /// digest record. The repeating `UNCalendarNotificationTrigger`
    /// fires the *placeholder* notification at the scheduled time;
    /// this one carries the actual count + summary so the user sees
    /// useful information at-a-glance.
    private func postDigestNotification(digest: SharedContainer.DailyDigestRecord) async {
        let content = UNMutableNotificationContent()
        let total = digest.totalEvents
        if total == 0 {
            content.title = "Quiet overnight"
            content.body = "No motion events from your cameras."
        } else {
            content.title = "\(total) event\(total == 1 ? "" : "s") overnight"
            let cameraNames = digest.perCameraCounts.prefix(3).map { $0.cameraName }
            content.body = "Across \(digest.perCameraCounts.count) camera\(digest.perCameraCounts.count == 1 ? "" : "s") · \(cameraNames.joined(separator: ", "))"
        }
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [Self.userInfoDigestDayKey: digest.day.timeIntervalSince1970]

        let request = UNNotificationRequest(
            identifier: "com.reolens.overnightDigest.fire-\(Int(digest.day.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.warning("Couldn't post digest summary notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

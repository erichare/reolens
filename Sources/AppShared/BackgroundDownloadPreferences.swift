import Foundation

/// 0.5.1 — User preferences governing background download behavior.
///
/// `allowCellular` defaults to OFF so a fresh install never burns
/// cellular data without consent. The flag is read at task-enqueue
/// time and applied per-task via `URLSessionTask.allowsCellularAccess`
/// — the underlying background `URLSessionConfiguration` stays
/// Wi-Fi-only, so any old enqueues without an explicit per-task
/// override remain conservative.
///
/// Backed by `UserDefaults` only (no iCloud sync) — cellular plans
/// vary device-to-device, so a per-device preference is the safer
/// default. Users with multiple devices can flip each independently.
public enum BackgroundDownloadPreferences {
    public static let allowCellularKey = "com.reolens.bookmarkDL.allowCellular"

    public static var allowCellular: Bool {
        get { UserDefaults.standard.bool(forKey: allowCellularKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowCellularKey) }
    }
}

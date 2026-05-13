import Foundation
import Observation

/// 0.5.1 — Per-camera notification on/off preferences.
///
/// Default behavior: every camera fires notifications. The user can
/// silence individual cameras (e.g. an indoor camera they don't want
/// pinging while they're home) and the preference syncs across their
/// Apple devices via `NSUbiquitousKeyValueStore`.
///
/// Stored inverted (mute set) for the same reason as
/// `HubExpansionStore`: the empty-on-first-launch state matches the
/// desired "everything on" default with zero data.
@MainActor
@Observable
public final class CameraNotificationPreferences {
    public static let shared = CameraNotificationPreferences()

    private(set) public var mutedCameras: Set<UUID> = []

    // `nonisolated` so the off-main-actor reader can use it without
    // hopping isolation. The keys are constants — no race.
    nonisolated private static let storeKey = "com.reolens.mutedCameraNotifications"
    nonisolated private static let debounceNanos: UInt64 = 750_000_000

    private let kv = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var pendingWrite: Task<Void, Never>?
    private var externalObserver: (any NSObjectProtocol)?

    public init() {
        let cloud = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let local = defaults.stringArray(forKey: Self.storeKey) ?? []
        let raw = cloud.isEmpty ? local : cloud
        self.mutedCameras = Set(raw.compactMap(UUID.init(uuidString:)))

        externalObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromCloud() }
        }
        kv.synchronize()
    }

    /// Non-isolated peek for code on background queues (e.g. the
    /// notification dispatch pipeline can call this without hopping to
    /// the main actor). Reads UserDefaults directly — kept in lockstep
    /// with the iCloud store by the debounced writer.
    nonisolated public static func isNotificationsEnabledOffMainActor(for cameraID: UUID) -> Bool {
        let raw = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        return !raw.contains(cameraID.uuidString)
    }

    public func isNotificationsEnabled(for cameraID: UUID) -> Bool {
        !mutedCameras.contains(cameraID)
    }

    public func setNotificationsEnabled(_ enabled: Bool, for cameraID: UUID) {
        if enabled {
            guard mutedCameras.contains(cameraID) else { return }
            mutedCameras.remove(cameraID)
        } else {
            let (inserted, _) = mutedCameras.insert(cameraID)
            guard inserted else { return }
        }
        scheduleWrite()
    }

    /// Prune state for a removed camera so the iCloud KV index stays
    /// bounded.
    public func forget(deviceID: UUID) {
        guard mutedCameras.contains(deviceID) else { return }
        mutedCameras.remove(deviceID)
        scheduleWrite()
    }

    private func reloadFromCloud() {
        let raw = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let updated = Set(raw.compactMap(UUID.init(uuidString:)))
        guard updated != mutedCameras else { return }
        mutedCameras = updated
        defaults.set(raw, forKey: Self.storeKey)
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snapshot = mutedCameras.map(\.uuidString).sorted()
        // Keep UserDefaults in lockstep immediately so the
        // off-main-actor read above sees current state without
        // waiting for the iCloud round-trip.
        defaults.set(snapshot, forKey: Self.storeKey)
        pendingWrite = Task { @MainActor [snapshot] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled else { return }
            kv.set(snapshot, forKey: Self.storeKey)
            kv.synchronize()
        }
    }
}

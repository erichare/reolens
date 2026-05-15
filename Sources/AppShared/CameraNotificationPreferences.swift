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
///
/// 0.6.3 — Mute is now addressable at two granularities:
///   * `(deviceID)` mutes the entire device or hub.
///   * `(deviceID, channel)` mutes one camera nested under a hub
///     without affecting its siblings.
/// Device-level mute supersedes channel state — a muted hub silences
/// every channel regardless of per-channel toggles. Toggling the hub
/// off and back on preserves whatever per-channel mutes the user had
/// configured, so they don't have to redo the work.
@MainActor
@Observable
public final class CameraNotificationPreferences {
    public static let shared = CameraNotificationPreferences()

    /// Set of fully-muted devices/hubs. Whole-device mute supersedes
    /// any per-channel state — see `isNotificationsEnabled(for:channel:)`.
    private(set) public var mutedCameras: Set<UUID> = []

    /// Set of muted `(deviceID, channel)` pairs. Independent of
    /// `mutedCameras` — toggling the device on/off does not modify
    /// this set, so the user's channel-level choices survive a hub
    /// mute/unmute cycle.
    private(set) public var mutedChannels: Set<ChannelKey> = []

    /// Composite identifier for the channel-level mute set.
    public struct ChannelKey: Hashable, Sendable {
        public let deviceID: UUID
        public let channel: Int

        public init(deviceID: UUID, channel: Int) {
            self.deviceID = deviceID
            self.channel = channel
        }

        /// On-disk encoding — UUID and channel joined with a colon.
        /// Persisted as `[String]` in `UserDefaults` /
        /// `NSUbiquitousKeyValueStore` so the existing array-of-string
        /// sync shape is reusable.
        fileprivate var storageString: String {
            "\(deviceID.uuidString):\(channel)"
        }

        fileprivate init?(storageString raw: String) {
            // Split on the final ':' — UUID strings contain hyphens
            // but no colons, so this is unambiguous.
            guard let sep = raw.lastIndex(of: ":") else { return nil }
            let idPart = String(raw[..<sep])
            let channelPart = String(raw[raw.index(after: sep)...])
            guard let id = UUID(uuidString: idPart), let ch = Int(channelPart) else {
                return nil
            }
            self.deviceID = id
            self.channel = ch
        }
    }

    // `nonisolated` so the off-main-actor reader can use it without
    // hopping isolation. The keys are constants — no race.
    nonisolated private static let storeKey = "com.reolens.mutedCameraNotifications"
    nonisolated private static let channelStoreKey = "com.reolens.mutedChannelNotifications"
    nonisolated private static let debounceNanos: UInt64 = 750_000_000

    private let kv = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var pendingWrite: Task<Void, Never>?
    private var externalObserver: (any NSObjectProtocol)?

    public init() {
        let cloudDev = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let localDev = defaults.stringArray(forKey: Self.storeKey) ?? []
        let rawDev = cloudDev.isEmpty ? localDev : cloudDev
        self.mutedCameras = Set(rawDev.compactMap(UUID.init(uuidString:)))

        let cloudCh = (kv.array(forKey: Self.channelStoreKey) as? [String]) ?? []
        let localCh = defaults.stringArray(forKey: Self.channelStoreKey) ?? []
        let rawCh = cloudCh.isEmpty ? localCh : cloudCh
        self.mutedChannels = Set(rawCh.compactMap(ChannelKey.init(storageString:)))

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
    ///
    /// Pass `channel` to check a specific camera under a hub. When
    /// `channel` is nil, only the device-level mute is consulted —
    /// preserving the pre-0.6.3 contract for any out-of-process call
    /// site that hasn't been threaded through with channel info.
    nonisolated public static func isNotificationsEnabledOffMainActor(
        for cameraID: UUID,
        channel: Int? = nil
    ) -> Bool {
        let dev = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        if dev.contains(cameraID.uuidString) { return false }
        guard let channel else { return true }
        let ch = UserDefaults.standard.stringArray(forKey: channelStoreKey) ?? []
        return !ch.contains(ChannelKey(deviceID: cameraID, channel: channel).storageString)
    }

    /// True when notifications are enabled for the given target.
    /// Channel-level mute is independent of device-level mute; the
    /// device-level mute wins ("hub muted ⇒ every channel muted").
    public func isNotificationsEnabled(for cameraID: UUID, channel: Int? = nil) -> Bool {
        if mutedCameras.contains(cameraID) { return false }
        guard let channel else { return true }
        return !mutedChannels.contains(ChannelKey(deviceID: cameraID, channel: channel))
    }

    /// Flip the mute state for either a whole device (when `channel`
    /// is nil) or a specific channel under that device.
    public func setNotificationsEnabled(
        _ enabled: Bool,
        for cameraID: UUID,
        channel: Int? = nil
    ) {
        if let channel {
            let key = ChannelKey(deviceID: cameraID, channel: channel)
            if enabled {
                guard mutedChannels.contains(key) else { return }
                mutedChannels.remove(key)
            } else {
                let (inserted, _) = mutedChannels.insert(key)
                guard inserted else { return }
            }
        } else {
            if enabled {
                guard mutedCameras.contains(cameraID) else { return }
                mutedCameras.remove(cameraID)
            } else {
                let (inserted, _) = mutedCameras.insert(cameraID)
                guard inserted else { return }
            }
        }
        scheduleWrite()
    }

    /// Prune state for a removed camera so the iCloud KV index stays
    /// bounded. Strips both the device-level mute and every
    /// channel-level mute belonging to it.
    public func forget(deviceID: UUID) {
        let hadDevice = mutedCameras.contains(deviceID)
        let channelsToDrop = mutedChannels.filter { $0.deviceID == deviceID }
        guard hadDevice || !channelsToDrop.isEmpty else { return }
        mutedCameras.remove(deviceID)
        mutedChannels.subtract(channelsToDrop)
        scheduleWrite()
    }

    private func reloadFromCloud() {
        let rawDev = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let rawCh = (kv.array(forKey: Self.channelStoreKey) as? [String]) ?? []
        let updatedDev = Set(rawDev.compactMap(UUID.init(uuidString:)))
        let updatedCh = Set(rawCh.compactMap(ChannelKey.init(storageString:)))
        let devChanged = updatedDev != mutedCameras
        let chChanged = updatedCh != mutedChannels
        guard devChanged || chChanged else { return }
        if devChanged {
            mutedCameras = updatedDev
            defaults.set(rawDev, forKey: Self.storeKey)
        }
        if chChanged {
            mutedChannels = updatedCh
            defaults.set(rawCh, forKey: Self.channelStoreKey)
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let devSnapshot = mutedCameras.map(\.uuidString).sorted()
        let chSnapshot = mutedChannels.map(\.storageString).sorted()
        // Keep UserDefaults in lockstep immediately so the
        // off-main-actor read above sees current state without
        // waiting for the iCloud round-trip.
        defaults.set(devSnapshot, forKey: Self.storeKey)
        defaults.set(chSnapshot, forKey: Self.channelStoreKey)
        pendingWrite = Task { @MainActor [devSnapshot, chSnapshot] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled else { return }
            kv.set(devSnapshot, forKey: Self.storeKey)
            kv.set(chSnapshot, forKey: Self.channelStoreKey)
            kv.synchronize()
        }
    }
}

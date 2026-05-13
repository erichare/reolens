import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// 0.5.1 — owns the "is this hub group expanded in the sidebar"
/// preference. Stored inverted (collapsed set) so the default of
/// "everything expanded" needs zero entries on a fresh install — which
/// matches the user's stated preference that hubs auto-expand by
/// default and only stay collapsed if explicitly closed.
///
/// Synced via `NSUbiquitousKeyValueStore` so collapsing a hub on the
/// Mac persists to the iPad and iPhone within ~30 s. A local
/// `UserDefaults` mirror keeps it functional when iCloud is signed
/// out or unreachable (no crashes, just no cross-device sync).
///
/// Threading: MainActor-isolated to keep SwiftUI bindings simple.
/// Writes coalesce on a short debounce so a series of expand/collapse
/// toggles doesn't burn the `NSUbiquitousKeyValueStore` 1024-key /
/// 1 MB quota.
@MainActor
@Observable
public final class HubExpansionStore {
    public static let shared = HubExpansionStore()

    private(set) public var collapsedHubs: Set<UUID> = []

    private static let storeKey = "com.reolens.collapsedHubs"
    private static let debounceNanos: UInt64 = 750_000_000

    private let kv = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var pendingWrite: Task<Void, Never>?
    private var externalObserver: (any NSObjectProtocol)?

    public init() {
        // Local mirror first — it's authoritative until iCloud KV
        // delivers an `didChangeExternally` callback. Falling back to
        // local when KV is empty preserves state across reinstalls on
        // devices not signed into iCloud.
        let cloud = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let local = (defaults.stringArray(forKey: Self.storeKey)) ?? []
        let raw = cloud.isEmpty ? local : cloud
        self.collapsedHubs = Set(raw.compactMap(UUID.init(uuidString:)))

        externalObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromCloud() }
        }
        // Ask the system to refresh the local KV mirror so a first
        // launch on a new device picks up an already-synced set.
        kv.synchronize()
    }

    // No `deinit` — `HubExpansionStore` is a process-lifetime singleton
    // and Swift 6 strict-concurrency forbids touching MainActor-isolated
    // state from a nonisolated `deinit`. The notification observer will
    // be reclaimed by the system when the app exits.

    public func isExpanded(deviceID: UUID) -> Bool {
        !collapsedHubs.contains(deviceID)
    }

    public func setExpanded(_ expanded: Bool, for deviceID: UUID) {
        if expanded {
            guard collapsedHubs.contains(deviceID) else { return }
            collapsedHubs.remove(deviceID)
        } else {
            let (inserted, _) = collapsedHubs.insert(deviceID)
            guard inserted else { return }
        }
        scheduleWrite()
    }

    /// Forget collapse state for a removed device so the index stays
    /// pruned. Callers are CameraStore.remove(...) and similar.
    public func forget(deviceID: UUID) {
        guard collapsedHubs.contains(deviceID) else { return }
        collapsedHubs.remove(deviceID)
        scheduleWrite()
    }

    private func reloadFromCloud() {
        let raw = (kv.array(forKey: Self.storeKey) as? [String]) ?? []
        let updated = Set(raw.compactMap(UUID.init(uuidString:)))
        guard updated != collapsedHubs else { return }
        collapsedHubs = updated
        defaults.set(raw, forKey: Self.storeKey)
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snapshot = collapsedHubs.map(\.uuidString).sorted()
        pendingWrite = Task { @MainActor [snapshot] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled else { return }
            kv.set(snapshot, forKey: Self.storeKey)
            defaults.set(snapshot, forKey: Self.storeKey)
            kv.synchronize()
        }
    }
}

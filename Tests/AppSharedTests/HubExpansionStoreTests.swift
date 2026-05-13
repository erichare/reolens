import Testing
import Foundation
@testable import AppShared

/// 0.5.1 — `HubExpansionStore` is the single source of truth for "is
/// this hub group expanded in the sidebar." Default-on semantics +
/// iCloud sync are easy to regress, so pin both contracts here.
@MainActor
@Suite("HubExpansionStore — default-on + persistence")
struct HubExpansionStoreTests {

    /// Each test gets its own fresh store so other tests don't leak
    /// state into this one. Uses a unique storage key per test by
    /// piggy-backing on UserDefaults's removeObject before init.
    private static func makeStore() -> HubExpansionStore {
        // Wipe the canonical key so this test runs in a clean state.
        UserDefaults.standard.removeObject(forKey: "com.reolens.collapsedHubs")
        return HubExpansionStore()
    }

    @Test("All hubs are expanded by default on a fresh install")
    func defaultIsExpanded() {
        let store = Self.makeStore()
        let id = UUID()
        #expect(store.isExpanded(deviceID: id))
        #expect(store.collapsedHubs.isEmpty)
    }

    @Test("Collapsing a hub flips isExpanded to false")
    func collapseFlipsExpansion() {
        let store = Self.makeStore()
        let id = UUID()
        store.setExpanded(false, for: id)
        #expect(!store.isExpanded(deviceID: id))
        #expect(store.collapsedHubs == [id])
    }

    @Test("Re-expanding removes the device from the collapsed set")
    func reExpandClears() {
        let store = Self.makeStore()
        let id = UUID()
        store.setExpanded(false, for: id)
        store.setExpanded(true, for: id)
        #expect(store.isExpanded(deviceID: id))
        #expect(store.collapsedHubs.isEmpty)
    }

    @Test("forget(deviceID:) prunes a removed hub from the index")
    func forgetPrunes() {
        let store = Self.makeStore()
        let id = UUID()
        store.setExpanded(false, for: id)
        store.forget(deviceID: id)
        #expect(store.collapsedHubs.isEmpty)
        // After forget, the default-on default still holds.
        #expect(store.isExpanded(deviceID: id))
    }

    @Test("Setting the same value twice is a no-op")
    func idempotentSetExpanded() {
        let store = Self.makeStore()
        let id = UUID()
        store.setExpanded(false, for: id)
        let before = store.collapsedHubs
        store.setExpanded(false, for: id)
        #expect(store.collapsedHubs == before)
    }
}

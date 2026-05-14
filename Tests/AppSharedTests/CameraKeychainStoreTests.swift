import Testing
import Foundation
@testable import AppShared

/// 0.6.0 Slice 15b — `CameraKeychainStore` wraps the system Keychain
/// calls extracted from `CameraStore`. Tests pin the wrapper-level
/// invariants:
///
/// - The MigrationResult type exposed to clients is a public mirror
///   of the package-private `Keychain.MigrationResult` and round-
///   trips its counts.
/// - The iCloud sync toggle round-trips through UserDefaults so a
///   fresh instance picks up the previous setting.
/// - `passwordSaveError` is observable and clearable (the existing
///   alert-presentation pattern).
///
/// The actual Keychain read / write path is exercised by the
/// production app — the system Keychain is intentionally not
/// addressable here so a CI run doesn't pollute the developer's
/// macOS login keychain.
@MainActor
@Suite("CameraKeychainStore")
struct CameraKeychainStoreTests {

    @Test("passwordSaveError is nil on a fresh store")
    func defaultErrorIsNil() {
        let store = CameraKeychainStore()
        #expect(store.passwordSaveError == nil)
    }

    @Test("passwordSaveError can be set and cleared")
    func setAndClearError() {
        let store = CameraKeychainStore()
        store.passwordSaveError = PasswordSaveError(deviceID: UUID(), message: "oops")
        #expect(store.passwordSaveError != nil)
        store.passwordSaveError = nil
        #expect(store.passwordSaveError == nil)
    }

    @Test("iCloudSyncEnabled round-trips through UserDefaults")
    func iCloudSyncToggle() {
        // Capture and restore the prior value so the test doesn't
        // pollute the developer's real preferences. CameraKeychain
        // Store reads/writes through `.standard` for parity with the
        // Keychain enum, so the cleanest isolation is to save+restore.
        let key = Keychain.syncDefaultsKey
        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        let store = CameraKeychainStore()
        store.iCloudSyncEnabled = true
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(store.iCloudSyncEnabled)

        // A fresh instance reads the persisted value.
        let other = CameraKeychainStore()
        #expect(other.iCloudSyncEnabled)

        store.iCloudSyncEnabled = false
        #expect(!UserDefaults.standard.bool(forKey: key))
    }

    @Test("MigrationResult mirrors the inner Keychain.MigrationResult counts")
    func migrationResultShape() {
        // `migrate(accounts:toSync:)` on an empty list is a no-op
        // that returns 0/0 without touching the system Keychain.
        let store = CameraKeychainStore()
        let result = store.migrate(accounts: [], toSync: false)
        #expect(result.migrated == 0)
        #expect(result.skipped == 0)
    }
}

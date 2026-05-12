import Foundation
import Security
import os

/// Per-camera password storage. Backed by the system Keychain.
///
/// By default (AGENTS.md §4 default), items are written with
/// `kSecAttrSynchronizable: false` — passwords stay device-local and never
/// reach iCloud Keychain. Starting in 0.4.0, the user can opt in via the
/// `iCloudKeychainSync` UserDefaults flag (Settings → "Sync passwords to
/// iCloud Keychain"). With sync on, new writes set the attribute to true
/// so the items replicate through iCloud Keychain to the user's other
/// devices.
///
/// Reads always match `kSecAttrSynchronizableAny` so a device that has
/// just turned the toggle off can still see passwords that were synced
/// in earlier — turning the toggle off is a write-side preference, not
/// a "hide previously-synced data" command.
///
/// Logging notes (AGENTS.md §11): we never log the password, the account
/// UUID's full form, or the host. The category-only Logger here exists so
/// migration counts and OSStatus errors land in unified logging.
package enum Keychain {
    private static let service = "com.reolens.cameraPassword"

    /// UserDefaults key for the user's iCloud Keychain opt-in. Default
    /// false — i.e. device-local — to preserve the AGENTS.md §4 default.
    package static let syncDefaultsKey = "com.reolens.iCloudKeychainSync"

    /// Whether writes should mark new items as synchronizable. Reads the
    /// `UserDefaults` flag; absence ⇒ false.
    package static var syncEnabled: Bool {
        UserDefaults.standard.bool(forKey: syncDefaultsKey)
    }

    package static func set(password: String, for id: UUID) {
        set(password: password, for: id, synchronized: syncEnabled)
    }

    /// Explicit form used by the migration helper, where the caller knows
    /// the target sync side.
    package static func set(password: String, for id: UUID, synchronized: Bool) {
        let account = id.uuidString
        guard let data = password.data(using: .utf8) else { return }
        deletePassword(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: synchronized ? kCFBooleanTrue as Any
                                                           : kCFBooleanFalse as Any
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("SecItemAdd failed status=\(status, privacy: .public) sync=\(synchronized, privacy: .public)")
        }
    }

    package static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            // Read regardless of which side the item lives on. The user
            // may have toggled sync off after previously syncing — the
            // iCloud-side item is still valid on this device.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    package static func deletePassword(for id: UUID) {
        // Match on `kSecAttrSynchronizableAny` so legacy local-only items
        // AND any synced items are both removed.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Re-save each known password with the new synchronization side.
    /// Used when the user toggles the iCloud Keychain Sync setting. Items
    /// without an existing password are skipped silently (a synced device
    /// may already have them, or the user never set one).
    ///
    /// Returns counts for UI feedback. Never throws; OSStatus errors are
    /// logged but don't abort the loop.
    @discardableResult
    package static func migrate(accounts: [UUID], toSync syncOn: Bool) -> MigrationResult {
        var migrated = 0
        var skipped = 0
        for id in accounts {
            guard let existing = password(for: id) else {
                skipped += 1
                continue
            }
            // `set(password:for:synchronized:)` calls deletePassword first
            // and then re-adds on the requested side. After this, only one
            // copy exists — the previous side is gone.
            set(password: existing, for: id, synchronized: syncOn)
            migrated += 1
        }
        log.info("Keychain migration toSync=\(syncOn, privacy: .public) migrated=\(migrated, privacy: .public) skipped=\(skipped, privacy: .public)")
        return MigrationResult(migrated: migrated, skipped: skipped)
    }

    package struct MigrationResult: Sendable, Equatable {
        package let migrated: Int
        package let skipped: Int
    }

    private static let log = Logger(subsystem: "com.reolens.Reolens", category: "Keychain")
}

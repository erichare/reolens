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

    @discardableResult
    package static func set(password: String, for id: UUID) -> Bool {
        // Try the user's chosen sync side first. If it fails because
        // the binary lacks the iCloud Keychain entitlement (common on
        // ad-hoc-signed `swift build` outputs, whose `dev`
        // entitlements deliberately drop the iCloud container to
        // avoid AMFI launch failures), retry with sync off. The
        // local-only side has no entitlement requirement at all, so
        // the fallback should always succeed on a working keychain.
        // The user can re-enable sync later from a Developer-ID-
        // signed build that has the iCloud entitlement.
        let preferred = syncEnabled
        if set(password: password, for: id, synchronized: preferred) {
            return true
        }
        if preferred {
            log.warning("Keychain set with synchronized=true failed; retrying synchronized=false (likely a dev / ad-hoc signing build missing the iCloud entitlement)")
            return set(password: password, for: id, synchronized: false)
        }
        return false
    }

    /// Explicit form used by the migration helper, where the caller knows
    /// the target sync side. Returns true iff the password is readable
    /// back from Keychain after the write — call sites use this to
    /// surface failures (the previous version silently logged and
    /// returned, which made "set the password" silently fail when a
    /// stale iCloud-synced Keychain item resisted deletion).
    @discardableResult
    package static func set(password: String, for id: UUID, synchronized: Bool) -> Bool {
        let account = id.uuidString
        guard let data = password.data(using: .utf8) else { return false }

        // Try a best-effort delete first to make room for the add.
        // `kSecAttrSynchronizableAny` matches local + iCloud-synced
        // items so a sync-on → sync-off → set sequence doesn't leave
        // a stale synced item shadowing the local one. Status is
        // tolerated: errSecItemNotFound is normal (first set), and
        // errSecDuplicateItem can't happen on a delete.
        deletePassword(for: id)

        let baseAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronized ? kCFBooleanTrue as Any
                                                           : kCFBooleanFalse as Any
        ]
        let addQuery = baseAttrs.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return verifyAfterWrite(id: id)
        }
        if addStatus == errSecDuplicateItem {
            // Apple's Keychain occasionally returns this when an
            // iCloud-synced item the `delete` should have caught
            // sneaks back in via sync replication mid-operation.
            // Fall through to `SecItemUpdate` against the same item
            // — that succeeds where add wouldn't.
            log.info("Keychain SecItemAdd returned errSecDuplicateItem; falling back to SecItemUpdate")
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            let updateStatus = SecItemUpdate(baseAttrs as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus == errSecSuccess {
                return verifyAfterWrite(id: id)
            }
            log.error("SecItemUpdate fallback failed status=\(updateStatus, privacy: .public) sync=\(synchronized, privacy: .public)")
            return false
        }
        log.error("SecItemAdd failed status=\(addStatus, privacy: .public) sync=\(synchronized, privacy: .public)")
        return false
    }

    /// Read-after-write probe so callers can distinguish "system
    /// reported success" from "the data is actually retrievable."
    /// Some Keychain failure modes still return errSecSuccess on
    /// the write but the subsequent read finds nothing — usually a
    /// keychain-access-group entitlement mismatch under a fresh
    /// signing identity. Surfacing this turns silent regressions
    /// into observable ones.
    private static func verifyAfterWrite(id: UUID) -> Bool {
        if password(for: id) != nil {
            return true
        }
        log.error("Keychain write reported success but read-back found nothing for \(id, privacy: .private)")
        return false
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

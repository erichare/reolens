import Foundation
import Observation

/// 0.6.0 Slice 15b — Keychain-side carve-out from the CameraStore god
/// object.
///
/// Owns:
/// - Per-camera password writes / reads / deletes (delegating to the
///   package-private `Keychain` enum).
/// - The "did the last write succeed?" observable signal that
///   surfaces to the UI as an alert when iCloud Keychain Sync is
///   misconfigured on an ad-hoc-signed build.
/// - The iCloud Keychain Sync toggle (`iCloudSyncEnabled`) backed by
///   UserDefaults under the `Keychain.syncDefaultsKey`.
/// - Sync-side migration (`migrate(accounts:toSync:)`) that re-writes
///   every known camera's password to the chosen side.
///
/// CameraStore embeds one of these and proxies its existing public
/// surface (`setPassword`, `passwordSaveError`, `iCloudSyncEnabled`,
/// `migrateKeychainSyncSide`) so the dozens of consumers across the
/// macOS + iOS apps don't change.
@MainActor
@Observable
public final class CameraKeychainStore {

    /// Latest password-save failure, exposed for the UI's alert
    /// presentation. Set by `set(password:for:)` when the Keychain
    /// reports the write succeeded but the read-back finds nothing
    /// (typically a missing iCloud-Keychain entitlement on a dev
    /// build), or when both add + update outright fail.
    public var passwordSaveError: PasswordSaveError?

    public init() {}

    // MARK: - Writes

    /// Write a password to the system Keychain. Returns false on
    /// failure (and populates `passwordSaveError` with a user-facing
    /// message); true on success.
    @discardableResult
    public func set(password: String, for id: UUID) -> Bool {
        let saved = Keychain.set(password: password, for: id)
        if !saved {
            let message: String
            #if os(macOS)
            message = """
                The system Keychain rejected the password write.

                If you're running a locally-built Reolens (./Scripts/build-app.sh) and you previously enabled iCloud Keychain Sync, that's the cause — ad-hoc-signed dev builds don't have the iCloud-Keychain entitlement. Turn off iCloud Keychain Sync in Settings → Privacy, or use the Developer-ID-signed release DMG.

                Otherwise, run \u{0060}log show --predicate 'subsystem == "com.reolens.Reolens" AND category == "Keychain"' --info --last 5m\u{0060} in Terminal to see the exact OSStatus.
                """
            #else
            message = "The iOS Keychain rejected the password write. If you've enabled iCloud Keychain Sync, try turning it off in Settings → iCloud Keychain Sync and entering the password again."
            #endif
            passwordSaveError = PasswordSaveError(deviceID: id, message: message)
            return false
        }
        return true
    }

    // MARK: - Reads

    /// Read a password back from the Keychain. Returns nil when no
    /// item is present (e.g. a freshly-synced device that hasn't
    /// been given a password yet).
    public func password(for id: UUID) -> String? {
        Keychain.password(for: id)
    }

    // MARK: - Deletes

    /// Remove a camera's password. Called from `CameraListStore.remove`
    /// when the user deletes a camera, and from the iCloud Keychain
    /// migration helper.
    public func deletePassword(for id: UUID) {
        Keychain.deletePassword(for: id)
    }

    // MARK: - Sync toggle

    /// Whether new password writes are marked synchronizable. Stored
    /// in `UserDefaults` so the next launch picks up the same side
    /// without needing to query the Keychain.
    public var iCloudSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keychain.syncDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Keychain.syncDefaultsKey) }
    }

    /// Re-save each known password on the requested sync side. Used
    /// when the user toggles iCloud Keychain Sync — the previous
    /// items on the other side are removed, so this device's
    /// Keychain ends up with one canonical copy per camera.
    @discardableResult
    public func migrate(accounts: [UUID], toSync syncOn: Bool) -> MigrationResult {
        let kcResult = Keychain.migrate(accounts: accounts, toSync: syncOn)
        return MigrationResult(migrated: kcResult.migrated, skipped: kcResult.skipped)
    }

    /// Public-API mirror of `Keychain.MigrationResult` so call sites
    /// don't need to import the package-private type.
    public struct MigrationResult: Sendable, Equatable {
        public let migrated: Int
        public let skipped: Int

        public init(migrated: Int, skipped: Int) {
            self.migrated = migrated
            self.skipped = skipped
        }
    }
}

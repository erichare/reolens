import SwiftUI

/// Form section that exposes the AGENTS.md §4 iCloud Keychain Sync
/// opt-in. Shared by the macOS and iOS Settings surfaces so the
/// migration semantics, copy, and confirmation flow stay identical on
/// both platforms.
///
/// The default behavior remains device-local — this section is a
/// gateway to opt in. When the user flips the toggle on, every
/// existing camera password is migrated to the iCloud-synced side of
/// Keychain (and the local-only copy is removed by
/// `Keychain.migrate(...)`). Flipping it off only changes where *new*
/// writes go; existing iCloud-synced entries are left alone because
/// deleting them would harm the user's other devices.
public struct ICloudKeychainSyncSection: View {
    @Environment(CameraStore.self) private var store
    @State private var lastMigration: MigrationFeedback?

    public init() {}

    public var body: some View {
        Section("iCloud Keychain Sync") {
            Toggle("Sync camera passwords to iCloud Keychain", isOn: Binding(
                get: { store.iCloudKeychainSyncEnabled },
                set: { newValue in
                    // Flip the flag *first*, then migrate — the migration
                    // helper reads the flag indirectly via the `syncOn`
                    // argument, but downstream `Keychain.set` calls in the
                    // app rely on the flag matching at write time.
                    store.iCloudKeychainSyncEnabled = newValue
                    let result = store.migrateKeychainSync(toSync: newValue)
                    lastMigration = MigrationFeedback(
                        toSync: newValue,
                        migrated: result.migrated,
                        skipped: result.skipped
                    )
                }
            ))
            Text(rationaleCopy)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let lastMigration {
                feedbackRow(for: lastMigration)
            }
            Text(reversibilityCopy)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var rationaleCopy: String {
        store.iCloudKeychainSyncEnabled
            ? "Your camera passwords sync to your other Apple devices through iCloud Keychain. Reolens never sees your passwords — Apple encrypts them end-to-end."
            : "Off by default. Camera passwords stay on this device. Other Apple devices signed in to the same iCloud account see the camera list and have to re-enter the password locally."
    }

    private var reversibilityCopy: String {
        "Turning this off later only changes where new password edits are stored. Passwords already synced to iCloud Keychain stay there so your other devices keep working."
    }

    @ViewBuilder
    private func feedbackRow(for feedback: MigrationFeedback) -> some View {
        let symbol = feedback.toSync ? "icloud.fill" : "lock.shield.fill"
        let summary: String = {
            if feedback.migrated == 0 && feedback.skipped == 0 {
                return "No cameras to migrate yet."
            }
            let where_ = feedback.toSync ? "to iCloud Keychain" : "to device-only Keychain"
            return "Moved \(feedback.migrated) password\(feedback.migrated == 1 ? "" : "s") \(where_)."
        }()
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(summary).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private struct MigrationFeedback: Equatable {
        let toSync: Bool
        let migrated: Int
        let skipped: Int
    }
}

import AppKit
import Foundation
import Observation
import Sparkle

/// Thin SwiftUI wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle does the heavy lifting — appcast fetch, EdDSA signature check,
/// download, and replace-on-relaunch. This type exposes just two things the
/// UI cares about:
///
/// - `checkForUpdates()` — bound to the **About → Check for Updates…** menu
///   item. Triggers an explicit (user-initiated) update check that *always*
///   shows feedback (either "you're on the latest version" or the install
///   prompt).
/// - `canCheckForUpdates` — gates the menu item so it greys out while
///   another update check is already in flight, OR while the updater is
///   disabled (no public key configured — see below).
///
/// ### Public key gating
///
/// We only start Sparkle's scheduler when `SUPublicEDKey` in `Info.plist`
/// is non-empty. On dev/CI builds the key is the empty placeholder (the
/// release workflow injects the real value at tag-push time), and Sparkle
/// 2 hits a `precondition` that turns into a SIGTRAP on launch if you
/// pass `startingUpdater: true` without a key. That crashes the app the
/// moment the SwiftUI scene initializes — including in CI's smoke-launch
/// step. Gating on key presence keeps dev/CI builds bootable while
/// production builds (which do have the key) update normally.
///
/// In the disabled state the controller still exists, the About-panel
/// menu item still renders, but it's greyed out — and any release
/// metadata that flows through `Info.plist` (feed URL, schedule
/// interval) is preserved.
@MainActor
@Observable
public final class UpdaterController {
    /// The Sparkle controller. Always constructed so the menu item has
    /// something to bind to; `startingUpdater` is conditional.
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's `canCheckForUpdates` so the menu item can bind
    /// to it through SwiftUI's observation system. Always `false` when
    /// the updater wasn't started (empty `SUPublicEDKey`), regardless of
    /// what Sparkle would otherwise report.
    public private(set) var canCheckForUpdates: Bool

    /// Whether Sparkle's background scheduler is running. False on
    /// dev/CI builds (no `SUPublicEDKey` injected); true once the
    /// release workflow injects the real public key at build time.
    public let isUpdaterEnabled: Bool

    private var observation: NSKeyValueObservation?

    public init() {
        let publicKey = (Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) ?? ""
        let enabled = !publicKey.isEmpty
        self.isUpdaterEnabled = enabled
        self.controller = SPUStandardUpdaterController(
            startingUpdater: enabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.canCheckForUpdates = enabled && controller.updater.canCheckForUpdates
        if enabled {
            self.observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in
                    self?.canCheckForUpdates = value
                }
            }
        }
    }

    /// User-initiated update check (always shows feedback).
    /// No-op when the updater is disabled.
    public func checkForUpdates() {
        guard isUpdaterEnabled else { return }
        controller.checkForUpdates(nil)
    }
}

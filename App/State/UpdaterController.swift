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
    /// The Sparkle controller. Optional because `--smoke-test` and
    /// "no public key configured" both skip construction entirely —
    /// that codepath touches Sparkle's `SPUUpdater`, which has crashed
    /// CI smoke launches even with `startingUpdater: false`. We
    /// optimistically construct it only when both gates pass.
    private let controller: SPUStandardUpdaterController?

    /// Mirrors Sparkle's `canCheckForUpdates` so the menu item can bind
    /// to it through SwiftUI's observation system. Always `false` when
    /// the updater wasn't constructed.
    public private(set) var canCheckForUpdates: Bool

    /// Whether Sparkle's background scheduler is running. False on
    /// dev/CI builds (no `SUPublicEDKey` injected) and any
    /// `--smoke-test` launch; true once the release workflow injects
    /// the real public key at build time.
    public let isUpdaterEnabled: Bool

    private var observation: NSKeyValueObservation?

    public init() {
        let publicKey = (Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) ?? ""
        let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
        let enabled = !publicKey.isEmpty && !isSmokeTest
        self.isUpdaterEnabled = enabled
        if enabled {
            let ctl = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.controller = ctl
            self.canCheckForUpdates = ctl.updater.canCheckForUpdates
            self.observation = ctl.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in
                    self?.canCheckForUpdates = value
                }
            }
        } else {
            self.controller = nil
            self.canCheckForUpdates = false
        }
    }

    /// User-initiated update check (always shows feedback).
    /// No-op when the updater is disabled.
    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

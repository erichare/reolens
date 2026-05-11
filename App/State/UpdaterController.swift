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
///   another update check is already in flight. Reads Sparkle's published
///   `canCheckForUpdates` flag.
///
/// We construct the underlying `SPUStandardUpdaterController` with
/// `startingUpdater: true`, which kicks off the background scheduler. The
/// scheduler honors `SUEnableAutomaticChecks` and `SUScheduledCheckInterval`
/// from `Info.plist` (currently: once per day).
///
/// When `SUPublicEDKey` is the empty placeholder (development builds), all
/// the background machinery still runs but Sparkle refuses to *apply* any
/// update — the signature check fails by design. Production releases get
/// the real public key swapped in by the release workflow.
@MainActor
@Observable
public final class UpdaterController {
    /// The Sparkle controller. Strong reference — Sparkle's scheduled
    /// checks stop when the controller is deallocated.
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's `canCheckForUpdates` so the menu item can bind to
    /// it through SwiftUI's observation system. Updated whenever Sparkle
    /// flips the flag via KVO.
    public private(set) var canCheckForUpdates: Bool

    private var observation: NSKeyValueObservation?

    public init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        self.observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// User-initiated update check (always shows feedback).
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

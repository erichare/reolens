import Foundation
import Observation

/// Single source of truth for how often `CameraSession` polls motion +
/// AI state. Driven by app lifecycle (scenePhase observers) and by
/// `ProcessInfo.isLowPowerModeEnabled`. Centralized so a future change
/// to polling cadence touches one knob and propagates to every camera
/// session.
///
/// Intent → interval table:
///   .foreground  →  10 s (matches pre-0.6.0 baseline)
///   .background  →  60 s (battery-friendly while the app is suspended)
///   .lowPower    → 120 s (extra-frugal under iOS Low Power Mode /
///                          macOS Low Power)
///
/// The polling task reads `currentIntervalSeconds` between iterations,
/// so a phase change applied while a poll is in flight only affects the
/// NEXT sleep — bounded by the previous interval. Acceptable trade-off
/// for not having to cancel + restart the underlying Task on every
/// phase change.
@MainActor
@Observable
public final class AdaptivePollSchedule {
    public static let shared = AdaptivePollSchedule()

    public enum Intent: Sendable, Equatable {
        case foreground
        case background
        case lowPower
    }

    public private(set) var intent: Intent = .foreground
    public private(set) var isLowPowerModeEnabled: Bool

    private var lowPowerObserver: NSObjectProtocol?

    private init() {
        self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        // Observe Low Power Mode changes. The notification fires when
        // the user toggles it in Control Center / System Settings.
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor explicitly — the observer block is
            // delivered on the operation queue we passed in (which is
            // `.main`, but Swift's strict concurrency doesn't carry
            // that as a static guarantee).
            Task { @MainActor in
                self?.recomputeFromLowPower()
            }
        }
        // Seed the intent at construction time so callers that read
        // before any phase change still see the right cadence.
        recomputeFromLowPower()
    }

    // No deinit: `AdaptivePollSchedule.shared` is a process-lifetime
    // singleton, so the `NotificationCenter` observer never needs
    // explicit removal. Adding a deinit would require crossing the
    // MainActor isolation boundary for cleanup, which the language
    // (correctly) refuses.

    /// Called by the app's scene-phase observers when the app moves to
    /// the foreground.
    public func enteredForeground() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isLowPowerModeEnabled = lowPower
        intent = lowPower ? .lowPower : .foreground
    }

    /// Called by the app's scene-phase observers when the app moves to
    /// the background.
    public func enteredBackground() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isLowPowerModeEnabled = lowPower
        intent = lowPower ? .lowPower : .background
    }

    private func recomputeFromLowPower() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isLowPowerModeEnabled = lowPower
        if lowPower {
            intent = .lowPower
        } else if intent == .lowPower {
            // Coming out of low-power mode while still in the same scene
            // phase. Default to foreground; the next phase observer will
            // correct if needed.
            intent = .foreground
        }
    }

    /// Compute the interval for a given intent. Pure — used by both
    /// the property and by unit tests. `nonisolated` so callers can
    /// invoke it without an actor hop.
    nonisolated public static func intervalSeconds(for intent: Intent) -> TimeInterval {
        switch intent {
        case .foreground: return 10
        case .background: return 60
        case .lowPower:   return 120
        }
    }

    public var currentIntervalSeconds: TimeInterval {
        Self.intervalSeconds(for: intent)
    }
}

import Foundation
import Observation
import OSLog
import Security

#if canImport(HomeKit)
@preconcurrency import HomeKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "homekit-bridge")

/// 0.6.0 Slice B2 — HomeKit bridge scaffolding.
///
/// **Scope reality check** (from the 0.6.0 release plan): bridging a
/// non-HomeKit-certified RTSP camera into HomeKit Secure Video (HKSV)
/// is non-trivial. The full HKSV recording-tier requires Apple's
/// Made-for-HomeKit (MFi) program participation — without that, an
/// `HMCameraProfile` registration call fails at runtime regardless of
/// how the SwiftUI code is structured.
///
/// What this slice ships:
///
/// 1. The bridge's public surface: `availability`, `isExposureEnabled
///    (for:)`, `setExposureEnabled(_:for:)`. UI binds to these.
/// 2. Authorization + home-manager bring-up on iOS via HomeKit
///    framework calls.
/// 3. Per-camera opt-in toggle persisted on `CameraEntry.homeKitEnabled`
///    so users can choose which cameras would be exposed.
/// 4. Entitlement detection: the bridge inspects the running
///    process's entitlements and surfaces `.entitlementMissing` when
///    the build was signed without HomeKit. That keeps a dev-signed
///    build from spinning the home manager up just to crash.
///
/// What this slice DOES NOT ship (TODO for a follow-up that has the
/// entitlement + MFi cert):
///
/// - Actual `HMCameraProfile` registration that exposes each Reolink
///   camera to the Home app.
/// - The RTSP-frame → HKSV-stream piping (would live in
///   `pipeRTSPFrames(for:)` below — currently logs and returns).
/// - Baichuan AI tag → `HMCharacteristicEvent` translation for HKSV's
///   rich-notification face / package / vehicle / animal categories.
///
/// The actor is `@MainActor` because HomeKit's HMHomeManager delegate
/// callbacks run on the main thread and most consumers are SwiftUI
/// views.
@MainActor
@Observable
public final class HomeKitBridge {

    public enum Availability: Equatable, Sendable {
        /// The HomeKit framework is unreachable (e.g. running under
        /// a build that didn't link it).
        case frameworkUnavailable
        /// HomeKit is present but the binary doesn't carry the
        /// `com.apple.developer.homekit` entitlement. Visible on
        /// every locally-signed dev build until the user (or a
        /// future signed release) provisions it.
        case entitlementMissing
        /// HomeKit is present, entitled, but the user hasn't granted
        /// access to the app yet. Shown in Settings → Privacy →
        /// HomeKit.
        case permissionNotDetermined
        /// User denied the HomeKit permission. The toggle stays
        /// available; tapping it surfaces a "go to Settings" hint.
        case permissionDenied
        /// HomeKit is present, entitled, granted, and at least one
        /// home is configured. The bridge can register accessories
        /// (subject to MFi cert availability).
        case ready(homeNames: [String])
    }

    public private(set) var availability: Availability = .frameworkUnavailable
    /// The last error the bridge surfaced. Mirrors the same pattern
    /// `CameraKeychainStore.passwordSaveError` follows — UI presents
    /// it as an alert, then clears the value.
    public var lastError: String?

    /// 0.6.2 — dark prep flag for the full HomeKit integration. Stays
    /// `false` in 0.6.2 so the existing stubbed `registerAccessoryIfNeeded`
    /// path keeps no-opping; 0.7.0 flips this to `true` if Apple MFi
    /// certification lands and the entitlement merges in. Centralized
    /// here so every gated code path can guard on a single constant
    /// instead of scattering build-flag checks across the bridge.
    public static let fullIntegrationEnabled: Bool = false

    public init() {
        availability = .frameworkUnavailable
        refreshAvailability()
    }

    /// Re-run the entitlement + permission probe. Called from the
    /// settings section when the user enables HomeKit in System
    /// Settings and returns to Reolens.
    public func refreshAvailability() {
        #if canImport(HomeKit)
        guard Self.hasHomeKitEntitlement else {
            availability = .entitlementMissing
            return
        }
        // The HMHomeManager itself is the asynchronous source of
        // truth here — its delegate fires `homeManagerDidUpdateHomes`
        // when iOS has finished interrogating the Home database. We
        // surface a partial-state placeholder (`permissionNotDetermined`)
        // until the first update lands.
        if homeManager == nil {
            let manager = HMHomeManager()
            manager.delegate = delegateBox
            homeManager = manager
            availability = .permissionNotDetermined
        }
        #else
        availability = .frameworkUnavailable
        #endif
    }

    // MARK: - Per-camera exposure

    /// True iff the user has opted this camera in to HomeKit exposure.
    /// The flag is stored on the `CameraEntry` so it round-trips
    /// through `cameras.json` to other Apple devices, matching the
    /// existing per-camera-state pattern.
    public func isExposureEnabled(for entry: CameraEntry) -> Bool {
        entry.homeKitEnabled
    }

    /// Persist the exposure toggle. Callers route through
    /// `CameraStore` to ensure the change writes back to
    /// `cameras.json`; this helper holds the conversion + logging.
    public func setExposureEnabled(_ enabled: Bool, for entry: CameraEntry) -> CameraEntry {
        var updated = entry
        updated.homeKitEnabled = enabled
        log.info("HomeKit exposure \(enabled ? "enabled" : "disabled", privacy: .public) for camera \(entry.displayName, privacy: .public)")
        return updated
    }

    /// Stub for the future MFi-certified accessory registration.
    /// Currently logs and returns — the real implementation:
    ///
    /// 1. Looks up or creates an `HMAccessoryBrowser`-discovered
    ///    accessory matching `entry.id`.
    /// 2. Registers an `HMCameraProfile` with the user's primary
    ///    home.
    /// 3. Wires the camera's RTSP main stream into the profile's
    ///    `HMCameraStreamControl`.
    /// 4. Maps Baichuan AI tags (`people`, `vehicle`, `dog_cat`,
    ///    `package`, `face`) onto HMCharacteristicEvents so HKSV's
    ///    rich-notification stack picks them up.
    public func registerAccessoryIfNeeded(for entry: CameraEntry) async {
        guard case .ready = availability, entry.homeKitEnabled else { return }
        guard Self.fullIntegrationEnabled else {
            log.info("HomeKit accessory registration is stubbed — MFi certification + the com.apple.developer.homekit entitlement are required to expose Reolink cameras through HMCameraProfile. See HomeKitBridge.swift comments for the full plan.")
            return
        }
        // 0.7.0 — real HMCameraProfile registration lands here when
        // `fullIntegrationEnabled` flips. The behavior the stub above
        // describes is what runs in the meantime.
    }

    // MARK: - Internals

    #if canImport(HomeKit)
    @ObservationIgnored
    private var homeManager: HMHomeManager?
    @ObservationIgnored
    private lazy var delegateBox: HomeManagerDelegateBox = HomeManagerDelegateBox(owner: self)
    #endif

    /// Read the running binary's entitlements blob for
    /// `com.apple.developer.homekit`.
    ///
    /// macOS exposes `SecTaskCreateFromSelf` for this; iOS doesn't
    /// surface an equivalent API, so we instead rely on the
    /// `NSHomeKitUsageDescription` Info.plist check below (its
    /// presence is necessary for `HMHomeManager()` to not crash, so
    /// it stands in as a "build was provisioned for HomeKit" probe).
    /// Returns false on dev-signed builds that didn't have the
    /// entitlement merged in.
    static var hasHomeKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.homekit" as CFString
        let value = SecTaskCopyValueForEntitlement(task, key, nil)
        guard let cfBool = value as? Bool else { return false }
        return cfBool
        #else
        // iOS — surrogate for the entitlement check. Without
        // `NSHomeKitUsageDescription` in Info.plist, the first
        // `HMHomeManager()` call abort()s with a TCC privacy
        // violation. Surfacing the absence here keeps the bridge
        // from spinning the manager up on a misconfigured build.
        return Bundle.main.object(forInfoDictionaryKey: "NSHomeKitUsageDescription") != nil
        #endif
    }

    @MainActor
    fileprivate func homesDidUpdate(names: [String]) {
        if names.isEmpty {
            availability = .permissionDenied
        } else {
            availability = .ready(homeNames: names)
        }
    }
}

#if canImport(HomeKit)
/// HMHomeManagerDelegate isn't `@MainActor`-isolated, but our
/// `HomeKitBridge` is. Bridge the gap with a small non-isolated
/// wrapper that bounces the delegate callbacks onto MainActor.
private final class HomeManagerDelegateBox: NSObject, HMHomeManagerDelegate, @unchecked Sendable {
    weak var owner: HomeKitBridge?

    init(owner: HomeKitBridge) {
        self.owner = owner
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        let names = manager.homes.map(\.name)
        Task { @MainActor [weak self] in
            self?.owner?.homesDidUpdate(names: names)
        }
    }
}
#endif

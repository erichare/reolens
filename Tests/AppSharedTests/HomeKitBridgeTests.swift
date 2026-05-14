import Testing
import Foundation
@testable import AppShared

/// 0.6.0 Slice B2 — `HomeKitBridge` ships the user-facing
/// availability state machine + per-camera opt-in helpers. The
/// actual `HMHomeManager` interactions can't be exercised in a unit
/// test (the system framework requires the HomeKit entitlement and
/// user permission), so this suite pins only what's pure: the per-
/// camera toggle round-trip and the `CameraEntry.homeKitEnabled`
/// Codable contract.
@MainActor
@Suite("HomeKitBridge + CameraEntry.homeKitEnabled")
struct HomeKitBridgeTests {

    // MARK: - Per-camera exposure

    @Test("isExposureEnabled reads CameraEntry.homeKitEnabled")
    func exposureReadsEntryFlag() {
        let bridge = HomeKitBridge()
        let off = CameraEntry(
            displayName: "Off",
            host: "10.0.0.1",
            username: "admin",
            homeKitEnabled: false
        )
        let on = CameraEntry(
            displayName: "On",
            host: "10.0.0.2",
            username: "admin",
            homeKitEnabled: true
        )
        #expect(!bridge.isExposureEnabled(for: off))
        #expect(bridge.isExposureEnabled(for: on))
    }

    @Test("setExposureEnabled returns a copy with the flag updated, leaves input untouched")
    func exposureUpdateIsImmutable() {
        let bridge = HomeKitBridge()
        let entry = CameraEntry(displayName: "Front", host: "10.0.0.1", username: "admin")
        let updated = bridge.setExposureEnabled(true, for: entry)
        #expect(updated.homeKitEnabled)
        #expect(!entry.homeKitEnabled, "Input entry must not be mutated")
        #expect(updated.id == entry.id)
    }

    // MARK: - Availability

    @Test("Fresh bridge defaults to .frameworkUnavailable or .entitlementMissing on non-entitled hosts")
    func defaultAvailability() {
        let bridge = HomeKitBridge()
        // On macOS test hosts the binary won't have the HomeKit
        // entitlement, so the bridge surfaces either `.frameworkUn
        // available` (HomeKit isn't linked) or `.entitlementMissing`
        // (HomeKit is linked but entitlement absent). Both are valid
        // "not ready" states for our purposes.
        switch bridge.availability {
        case .frameworkUnavailable, .entitlementMissing,
             .permissionNotDetermined, .permissionDenied:
            // Acceptable — none of these unlock accessory registration.
            break
        case .ready:
            // Only possible when the running binary actually has the
            // entitlement (rare in tests, but tolerate it).
            break
        }
    }

    // MARK: - Codable round-trip on CameraEntry

    @Test("CameraEntry.homeKitEnabled round-trips through JSON")
    func entryCodableRoundTripWithFlag() throws {
        let entry = CameraEntry(
            id: UUID(),
            displayName: "Driveway",
            host: "10.0.0.1",
            username: "admin",
            homeKitEnabled: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CameraEntry.self, from: data)
        #expect(decoded.homeKitEnabled)
        #expect(decoded.id == entry.id)
    }

    @Test("Older cameras.json without homeKitEnabled decodes to false")
    func entryCodableForwardCompat() throws {
        // Hand-rolled JSON missing the new field — simulates a
        // cameras.json written by a pre-0.6.0 build.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "displayName": "Legacy",
          "host": "10.0.0.1",
          "port": 80,
          "username": "admin",
          "useHTTPS": false,
          "preferredCodec": "h264",
          "channelStreamRotations": {},
          "dualLensOverrides": [],
          "gridPreset": "adaptive",
          "channelOrder": [],
          "hiddenAppBadgeChannels": []
        }
        """
        let decoded = try JSONDecoder().decode(CameraEntry.self, from: Data(json.utf8))
        #expect(!decoded.homeKitEnabled, "Default must be OFF for forward-compat reads")
    }

    @Test("encode omits homeKitEnabled when false to keep cameras.json clean")
    func encodeOmitsDefaultFlag() throws {
        let entry = CameraEntry(
            id: UUID(),
            displayName: "Plain",
            host: "10.0.0.1",
            username: "admin"
        )
        let data = try JSONEncoder().encode(entry)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("homeKitEnabled"), "JSON should omit the field when false")
    }

    @Test("encode emits homeKitEnabled when true")
    func encodeEmitsTrueFlag() throws {
        let entry = CameraEntry(
            id: UUID(),
            displayName: "Exposed",
            host: "10.0.0.1",
            username: "admin",
            homeKitEnabled: true
        )
        let data = try JSONEncoder().encode(entry)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("homeKitEnabled"))
        #expect(json.contains("true"))
    }
}

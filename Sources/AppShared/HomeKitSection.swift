import SwiftUI

/// 0.6.0 Slice B2 — settings section for the HomeKit bridge.
///
/// Shows the current `HomeKitBridge.availability` state and (when
/// HomeKit is reachable) a per-camera "Expose to HomeKit" toggle
/// list. **iOS-only** — Apple ships HomeKit as a public framework
/// on iOS / iPadOS only; on macOS it lives under
/// PrivateFrameworks (not callable) and iOSSupport (Mac Catalyst
/// only). Native macOS apps like Reolens-for-Mac can't link against
/// it, so the section renders as an empty view there rather than
/// showing a misleading "framework not available on this device"
/// message.
///
/// The toggle persists through `CameraStore.setHomeKitEnabled(_:for:)`
/// which writes the updated entry back to `cameras.json` — that
/// means even on macOS the per-camera flag stays in sync via
/// iCloud, so a user flipping it on the iOS app sees the camera
/// surface in HomeKit on whichever iOS device has the entitlement
/// + MFi cert in the future.
public struct HomeKitSection: View {
    @Environment(CameraStore.self) private var store
    @Bindable public var bridge: HomeKitBridge

    public init(bridge: HomeKitBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        #if os(iOS)
        section
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private var section: some View {
        Section("HomeKit") {
            availabilityRow
            if case .ready(let homes) = bridge.availability {
                if !homes.isEmpty {
                    LabeledContent("Homes", value: homes.joined(separator: ", "))
                        .font(.caption)
                }
                Text("Cameras you toggle on will appear as HomeKit cameras in the user's selected Home. Full HomeKit Secure Video recording requires a future build signed with the HomeKit entitlement + Made-for-HomeKit certification — until then, the rich-notification side stays read-only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(store.orderedCameras()) { entry in
                    Toggle(isOn: Binding(
                        get: { entry.homeKitEnabled },
                        set: { newValue in store.setHomeKitEnabled(newValue, for: entry.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                            Text(entry.host)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if case .entitlementMissing = bridge.availability {
                Text("This build wasn't signed with the com.apple.developer.homekit entitlement. Locally-built (./Scripts/build-app.sh) and ad-hoc-signed releases land here; the Developer-ID release picks up the entitlement automatically. See HomeKitBridge.swift comments for the full requirement list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                bridge.refreshAvailability()
            } label: {
                Label("Re-check HomeKit status", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var availabilityRow: some View {
        switch bridge.availability {
        case .frameworkUnavailable:
            // Defensive — the iOS-only `#if` above means this state
            // shouldn't reach render. Kept as a fallback so a future
            // platform shift (Mac Catalyst, visionOS) can surface it
            // without a missing-case crash.
            Label("HomeKit isn't supported here yet.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .entitlementMissing:
            Label("Entitlement missing — see notes below", systemImage: "lock.shield")
                .foregroundStyle(.orange)
        case .permissionNotDetermined:
            Label("Checking HomeKit permission…", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .permissionDenied:
            Label("HomeKit access denied — enable it in Settings → Privacy & Security → HomeKit", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .ready(let homes):
            Label(
                homes.isEmpty ? "No homes configured yet — add one in the Home app." : "HomeKit ready",
                systemImage: "house.fill"
            )
            .foregroundStyle(homes.isEmpty ? .orange : .green)
        }
    }
}

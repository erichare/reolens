import SwiftUI

/// Surfaces a TLS-pinning mismatch to the user. Added in 0.4.1
/// alongside trust-on-first-use HTTPS pinning. The hub the user is
/// connecting to presented a different leaf cert than the one
/// recorded on first use — that's either:
///
///   1. The hub was reflashed / reset (legitimate; user should
///      "Trust new certificate").
///   2. A man-in-the-middle on the LAN (very unlikely but possible
///      on misconfigured / hostile networks; user should "Cancel").
///
/// The sheet surfaces both fingerprints so a technically inclined
/// user can verify out-of-band before trusting. AGENTS.md §3 — auth /
/// credentials / TLS PRs surface their reasoning in the UI rather
/// than silently fail.
public struct TrustChangeRequest: Sendable, Equatable, Identifiable {
    public let deviceID: UUID
    public let expected: String
    public let observed: String

    public var id: UUID { deviceID }

    public init(deviceID: UUID, expected: String, observed: String) {
        self.deviceID = deviceID
        self.expected = expected
        self.observed = observed
    }
}

public struct TrustChangedSheet: View {
    @Environment(CameraStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    public let request: TrustChangeRequest

    public init(request: TrustChangeRequest) {
        self.request = request
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Camera certificate changed")
                    .font(.title3.weight(.semibold))
            }
            Text(deviceName.map { "\"\($0)\" presented a different TLS certificate than the one Reolens recorded on first use." } ?? "This camera presented a different TLS certificate than the one Reolens recorded on first use.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("This usually means the camera was reset or its firmware was reflashed. If you didn't reset the camera, cancel and verify what's on your network before trusting the new certificate.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Expected").font(.caption.weight(.semibold))
                Text(request.expected)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Text("Observed").font(.caption.weight(.semibold))
                Text(request.observed)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.orange)
            }
            .padding(10)
            // 0.5.0 Liquid Glass — fingerprint comparison block reads
            // as a glass card inside the trust-changed dialog.
            .reolensGlassCard()
            HStack {
                Button("Cancel", role: .cancel) {
                    store.pendingTrustChange = nil
                    dismiss()
                }
                Spacer()
                Button("Trust new certificate") {
                    store.clearTLSFingerprint(for: request.deviceID)
                    store.pendingTrustChange = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460)
    }

    private var deviceName: String? {
        store.cameras.first(where: { $0.id == request.deviceID })?.displayName
    }
}

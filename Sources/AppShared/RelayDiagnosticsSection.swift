import SwiftUI

/// Settings section that surfaces `RelayDiagnostics` state to the
/// user. Each row colors itself red / orange / green based on the
/// outcome of the most recent observed event, and shows the timestamp
/// so the user can tell at-a-glance whether the relay actually fired
/// today. AGENTS.md §5 — all data is local; nothing leaves the
/// device.
///
/// The view compiles on both platforms (the source file lives in
/// AppShared). The body conditionally renders iOS-only subscriber
/// rows or macOS-only publisher rows via `#if os(...)`. A device that
/// publishes *and* subscribes (a hypothetical iPad NVR setup) is not
/// supported yet — see the 0.7.0 roadmap.
public struct RelayDiagnosticsSection: View {
    @State private var state: RelayDiagnosticsState = RelayDiagnosticsState()
    @State private var lastRefreshedAt: Date = .distantPast
    @State private var showingResetConfirm: Bool = false

    public init() {}

    public var body: some View {
        Section("Push diagnostics") {
            #if os(iOS)
            subscriberRows
            #elseif os(macOS)
            publisherRows
            #endif

            footerControls
        }
        .task { await reload() }
    }

    // MARK: - iOS subscriber-side rows

    #if os(iOS)
    @ViewBuilder
    private var subscriberRows: some View {
        DiagnosticsRow(
            label: "APNS registration",
            badge: apnsBadge,
            detail: apnsDetail
        )
        DiagnosticsRow(
            label: "CloudKit subscription",
            badge: subscriptionBadge,
            detail: subscriptionDetail
        )
        DiagnosticsRow(
            label: "Silent pushes (last 24 h)",
            badge: silentPushBadge,
            detail: silentPushDetail
        )
        DiagnosticsRow(
            label: "Schema decode",
            badge: decodeBadge,
            detail: decodeDetail
        )
        footerHelp(
            "Push notifications on iPhone / iPad ride through Apple's CloudKit on your own iCloud account. " +
            "If APNS is not registered or the CloudKit subscription failed, this device can't receive motion events from your Mac. " +
            "If you see APNS green and the subscription green but zero silent pushes in 24 h, the issue is likely on the publisher (Mac) side — turn on the macOS “Relay motion events to my other Apple devices” toggle and keep the Mac running. " +
            "A red “Schema decode” row means CloudKit Production is missing a field that the app needs — see docs/TESTFLIGHT_NOTIFICATIONS.md → Deploying schema changes."
        )
    }
    #endif

    // MARK: - macOS publisher-side rows

    #if os(macOS)
    @ViewBuilder
    private var publisherRows: some View {
        DiagnosticsRow(
            label: "CloudKit publish",
            badge: publisherBadge,
            detail: publisherDetail
        )
        DiagnosticsRow(
            label: "Events published (last 24 h)",
            badge: publisherCountBadge,
            detail: nil
        )
        footerHelp(
            "When you enable the relay above, this Mac writes a motion-event record into your iCloud private database every time a camera fires. " +
            "A red “CloudKit publish” row means the most recent attempt failed — most often because iCloud isn't signed in, the iCloud entitlement is missing on this build, or the iCloud account changed since you enrolled."
        )
    }
    #endif

    // MARK: - Shared controls

    @ViewBuilder
    private var footerControls: some View {
        HStack {
            Button("Refresh") {
                Task { await reload() }
            }
            Spacer()
            Button("Reset diagnostics", role: .destructive) {
                showingResetConfirm = true
            }
        }
        .alert(
            "Reset diagnostics?",
            isPresented: $showingResetConfirm
        ) {
            Button("Reset", role: .destructive) {
                Task {
                    await RelayDiagnostics.shared.reset()
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the last-success / last-failure history on this device. Won't affect cameras, the CloudKit subscription, or notification preferences.")
        }
    }

    private func reload() async {
        state = await RelayDiagnostics.shared.snapshot()
        lastRefreshedAt = Date()
    }

    private func footerHelp(_ text: String) -> Text {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: - Row composition

    #if os(iOS)
    private var apnsBadge: DiagnosticsBadge {
        if let failureAt = state.lastAPNSFailureAt,
           failureAt > (state.lastAPNSRegistrationAt ?? .distantPast) {
            return .failure
        }
        if state.lastAPNSRegistrationAt != nil { return .success }
        return .pending
    }

    private var apnsDetail: String {
        if let failureAt = state.lastAPNSFailureAt,
           failureAt > (state.lastAPNSRegistrationAt ?? .distantPast) {
            return "Failed \(DiagnosticsFormatter.relative(from: failureAt)) — \(state.lastAPNSFailureMessage ?? "no detail")"
        }
        if let at = state.lastAPNSRegistrationAt {
            let bytes = state.lastAPNSTokenByteCount.map { " · \($0)-byte token" } ?? ""
            return "Registered \(DiagnosticsFormatter.relative(from: at))\(bytes)"
        }
        return "Not yet registered. Grant notification permission and open the app once."
    }

    private var subscriptionBadge: DiagnosticsBadge {
        switch state.lastSubscriptionInstallSucceeded {
        case .some(true): return .success
        case .some(false): return .failure
        case .none: return .pending
        }
    }

    private var subscriptionDetail: String {
        guard let at = state.lastSubscriptionInstallAt else {
            return "Not yet attempted. The subscription installs on first launch after notification permission."
        }
        let outcome = state.lastSubscriptionInstallOutcome ?? "unknown"
        return "\(DiagnosticsFormatter.humanize(outcome)) \(DiagnosticsFormatter.relative(from: at))"
    }

    private var silentPushBadge: DiagnosticsBadge {
        let n = state.silentPushReceiptsLast24h.count
        if n > 0 { return .success }
        // No pushes is only an error if the subscription succeeded and
        // APNS is registered — otherwise upstream rows already flag the
        // problem.
        if state.lastSubscriptionInstallSucceeded == true,
           state.lastAPNSRegistrationAt != nil {
            return .warning
        }
        return .pending
    }

    private var silentPushDetail: String {
        let n = state.silentPushReceiptsLast24h.count
        if n == 0, let last = state.lastSilentPushAt {
            return "Last received \(DiagnosticsFormatter.relative(from: last))"
        }
        if n == 0 {
            return "No silent pushes received yet."
        }
        if let last = state.lastSilentPushAt {
            return "\(n) received · last \(DiagnosticsFormatter.relative(from: last))"
        }
        return "\(n) received"
    }

    private var decodeBadge: DiagnosticsBadge {
        if state.lastDecodeFailureAt != nil { return .failure }
        // No failure ever, and at least one push arrived → decoded
        // cleanly. Without any pushes there's no signal either way.
        if state.lastSilentPushAt != nil { return .success }
        return .pending
    }

    private var decodeDetail: String {
        if let at = state.lastDecodeFailureAt {
            let field = state.lastDecodeFailureField ?? "unknown field"
            return "Schema mismatch on '\(field)' \(DiagnosticsFormatter.relative(from: at)). " +
                "Production schema is likely missing this field — deploy from CloudKit Console."
        }
        if state.lastSilentPushAt != nil {
            return "Recent records decoded cleanly."
        }
        return "No records decoded yet."
    }
    #endif

    #if os(macOS)
    private var publisherBadge: DiagnosticsBadge {
        switch state.lastPublisherSaveSucceeded {
        case .some(true): return .success
        case .some(false): return .failure
        case .none: return .pending
        }
    }

    private var publisherDetail: String? {
        guard let at = state.lastPublisherSaveAt else {
            return "No publish attempts yet. Enable the toggle above and trigger a motion event on a camera."
        }
        let outcome = state.lastPublisherSaveOutcome ?? "unknown"
        return "\(DiagnosticsFormatter.humanize(outcome)) \(DiagnosticsFormatter.relative(from: at))"
    }

    private var publisherCountBadge: DiagnosticsBadge {
        state.publisherSaveCountLast24h > 0 ? .success : .pending
    }
    #endif
}

// MARK: - Subviews

/// Three-state badge: green / orange / red / muted. Pure presentation;
/// row content owns the label and detail strings.
enum DiagnosticsBadge: Sendable, Equatable {
    case success
    case warning
    case failure
    case pending

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .pending: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .pending: return .secondary
        }
    }
}

struct DiagnosticsRow: View {
    let label: String
    let badge: DiagnosticsBadge
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: badge.systemImage)
                    .foregroundStyle(badge.tint)
                Text(label)
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Shared date formatting for the diagnostics rows. Pulled out so the
/// snapshot tests can assert against a known formatter without
/// reaching into `DateFormatter` directly.
enum DiagnosticsFormatter {
    static func relative(from date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Render an outcome rawValue (e.g. "noEntitlement",
    /// "rateLimitedSuppressed") as a human-readable phrase
    /// ("No entitlement", "Rate limited suppressed"). The values stored
    /// in `RelayDiagnosticsState` are camelCase rawValues from the
    /// `RelayPublisherOutcome` / `RelaySubscriptionOutcome` enums, so a
    /// naive `.capitalized` mashes them into one word. CKError messages
    /// (which arrive prefixed with whitespace or punctuation) are
    /// returned unchanged.
    static func humanize(_ raw: String) -> String {
        // Don't reformat anything that looks like a CKError text:
        // those contain spaces, parens, or punctuation already.
        if raw.contains(" ") || raw.contains(":") {
            return raw
        }
        var spaced = ""
        for char in raw {
            if char.isUppercase, !spaced.isEmpty {
                spaced.append(" ")
                spaced.append(Character(char.lowercased()))
            } else {
                spaced.append(char)
            }
        }
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
}

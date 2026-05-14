import SwiftUI

/// User-facing notification log. Surfaces the rolling 1,000-record
/// `NotificationHistory` so the user can browse delivered (and
/// dropped) notifications, filter by camera / tag / status, and tap
/// through to a recording or live view.
///
/// Cross-platform — drives both the iOS Settings push-screen and the
/// macOS Settings → Diagnostics modal.
public struct NotificationLogView: View {
    @State private var records: [NotificationRecord] = []
    @State private var cameraFilter: UUID? = nil
    @State private var statusFilter: NotificationRecord.DeliveryStatus? = nil
    @State private var sourceFilter: NotificationRecord.Source? = nil
    @State private var showingClearConfirm: Bool = false
    @State private var loading: Bool = true

    public init() {}

    public var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if filteredRecords.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Notification log")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar { toolbarContent }
        .task { await reload() }
        .refreshable { await reload() }
        .alert(
            "Clear notification log?",
            isPresented: $showingClearConfirm
        ) {
            Button("Clear all", role: .destructive) {
                Task {
                    await NotificationHistory.shared.clear()
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes the on-device log. It does not affect notification settings, cameras, or anything else.")
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No notifications yet",
            systemImage: "bell.slash",
            description: Text("As motion events fire, every notification — delivered or silenced — lands here so you can see what happened.")
        )
    }

    @ViewBuilder
    private var list: some View {
        List {
            filterPills
            ForEach(groupedByDay, id: \.day) { group in
                Section(dayHeader(for: group.day)) {
                    ForEach(group.records) { record in
                        NotificationLogRow(record: record)
                    }
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#else
        .listStyle(.inset)
#endif
    }

    @ViewBuilder
    private var filterPills: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterPill(
                            label: "All sources",
                            isSelected: sourceFilter == nil
                        ) { sourceFilter = nil }
                        ForEach(activeSources, id: \.self) { source in
                            FilterPill(
                                label: source.shortLabel,
                                isSelected: sourceFilter == source
                            ) { sourceFilter = source }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterPill(
                            label: "Any status",
                            isSelected: statusFilter == nil
                        ) { statusFilter = nil }
                        ForEach(activeStatuses, id: \.self) { status in
                            FilterPill(
                                label: status.shortLabel,
                                isSelected: statusFilter == status,
                                tint: status.tint
                            ) { statusFilter = status }
                        }
                    }
                }
                if !activeCameras.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterPill(
                                label: "All cameras",
                                isSelected: cameraFilter == nil
                            ) { cameraFilter = nil }
                            ForEach(activeCameras, id: \.id) { camera in
                                FilterPill(
                                    label: camera.name,
                                    isSelected: cameraFilter == camera.id
                                ) { cameraFilter = camera.id }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Clear all…", role: .destructive) {
                    showingClearConfirm = true
                }
                Button("Refresh") {
                    Task { await reload() }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Data + filtering

    private func reload() async {
        loading = true
        defer { loading = false }
        records = await NotificationHistory.shared.snapshot()
    }

    private var filteredRecords: [NotificationRecord] {
        records.filter { record in
            if let cameraFilter, record.cameraID != cameraFilter { return false }
            if let statusFilter, record.deliveryStatus != statusFilter { return false }
            if let sourceFilter, record.source != sourceFilter { return false }
            return true
        }
    }

    private struct DayGroup {
        let day: Date
        let records: [NotificationRecord]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecords) { record in
            calendar.startOfDay(for: record.timestamp)
        }
        return grouped
            .map { DayGroup(day: $0.key, records: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    private func dayHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: day)
    }

    private struct CameraOption: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    private var activeCameras: [CameraOption] {
        // Use the records themselves as the source of truth for what
        // cameras appear in the filter list — keeps the filter pills
        // grounded to data the user can actually see.
        var seen: Set<UUID> = []
        var out: [CameraOption] = []
        for record in records {
            if !seen.contains(record.cameraID) {
                seen.insert(record.cameraID)
                out.append(CameraOption(id: record.cameraID, name: record.cameraName))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private var activeStatuses: [NotificationRecord.DeliveryStatus] {
        let unique = Set(records.map { $0.deliveryStatus })
        return NotificationRecord.DeliveryStatus.allCases.filter { unique.contains($0) }
    }

    private var activeSources: [NotificationRecord.Source] {
        let unique = Set(records.map { $0.source })
        return NotificationRecord.Source.allCases.filter { unique.contains($0) }
    }
}

// MARK: - Row + helpers

struct NotificationLogRow: View {
    let record: NotificationRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.deliveryStatus.systemImage)
                .foregroundStyle(record.deliveryStatus.tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.cameraName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(NotificationLogRow.relative(record.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if record.tappedAt != nil {
                        Image(systemName: "hand.tap.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Opened from notification")
                    }
                }
                if record.deliveryStatus != .posted {
                    Text(record.deliveryStatus.userLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(record.deliveryStatus.tint)
                }
            }
            Spacer()
            if record.source != .local {
                Image(systemName: record.source.systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(record.source.shortLabel)
            }
        }
        .padding(.vertical, 2)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

struct FilterPill: View {
    let label: String
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? tint.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(isSelected ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Display helpers

extension NotificationRecord.DeliveryStatus {
    var systemImage: String {
        switch self {
        case .posted: return "checkmark.circle.fill"
        case .throttledCooldown: return "hourglass"
        case .permissionDenied: return "exclamationmark.shield.fill"
        case .perCameraMuted, .tagMuted, .motionMutedGlobally, .aiMutedGlobally, .globallyDisabled:
            return "bell.slash.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .posted: return .green
        case .throttledCooldown: return .orange
        case .permissionDenied, .failed: return .red
        case .perCameraMuted, .tagMuted, .motionMutedGlobally, .aiMutedGlobally, .globallyDisabled:
            return .secondary
        }
    }

    /// Short pill label.
    var shortLabel: String {
        switch self {
        case .posted: return "Delivered"
        case .throttledCooldown: return "Throttled"
        case .permissionDenied: return "Permission off"
        case .perCameraMuted: return "Camera muted"
        case .tagMuted: return "Tag muted"
        case .motionMutedGlobally: return "Motion off"
        case .aiMutedGlobally: return "AI off"
        case .globallyDisabled: return "Notifications off"
        case .failed: return "Failed"
        }
    }

    /// Long-form user-facing label.
    var userLabel: String {
        switch self {
        case .posted: return "Delivered"
        case .throttledCooldown: return "Throttled — 30 s cooldown"
        case .permissionDenied: return "System permission off"
        case .perCameraMuted: return "Camera muted in Settings"
        case .tagMuted: return "AI tag muted in Settings"
        case .motionMutedGlobally: return "Motion notifications off"
        case .aiMutedGlobally: return "AI notifications off"
        case .globallyDisabled: return "Notifications disabled"
        case .failed: return "Failed to post"
        }
    }
}

extension NotificationRecord.Source {
    var systemImage: String {
        switch self {
        case .local: return "iphone"
        case .cloudKitSilentPush: return "icloud"
        case .digest: return "calendar"
        case .test: return "paperplane"
        }
    }

    var shortLabel: String {
        switch self {
        case .local: return "Local"
        case .cloudKitSilentPush: return "Relayed"
        case .digest: return "Digest"
        case .test: return "Test"
        }
    }
}

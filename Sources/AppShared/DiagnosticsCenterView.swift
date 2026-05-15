import SwiftUI

/// Browse-and-copy interface for the local `AppErrorRecorder` store.
/// Reachable from Settings → Advanced → "Diagnostics Center".
///
/// AGENTS.md §5: this view never sends data off-device. "Copy
/// diagnostic bundle" emits to the OS share sheet / pasteboard for the
/// user to forward manually — Reolens itself doesn't transmit
/// anything.
///
/// New in 0.6.1.
public struct DiagnosticsCenterView: View {

    @State private var records: [AppErrorRecord] = []
    @State private var counts: [AppError.Category: Int] = [:]
    @State private var loading: Bool = false
    @State private var selectedCategory: AppError.Category? = nil
    @State private var showingClearConfirm: Bool = false

    public init() {}

    public var body: some View {
        contentList
            .navigationTitle("Diagnostics Center")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await reload() }
            .toolbar { toolbarContent }
            .alert("Clear diagnostics log?", isPresented: $showingClearConfirm) {
                Button("Clear", role: .destructive) {
                    Task {
                        await AppErrorRecorder.shared.clear()
                        await reload()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all recorded errors from this device. The log is local only — nothing was ever uploaded.")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentList: some View {
        if loading && records.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredRecords.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    summaryRow
                }
                Section("Errors") {
                    ForEach(filteredRecords) { record in
                        DiagnosticsErrorRow(record: record)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No errors recorded",
            systemImage: "checkmark.seal",
            description: Text("Reolens hasn't logged any errors on this device. If something goes wrong while you're using the app, it'll show up here so you can decide whether to share it.")
        )
    }

    @ViewBuilder
    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Text("Local to this device. Nothing is uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !counts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(AppError.Category.allCases, id: \.self) { category in
                        if let count = counts[category], count > 0 {
                            DiagnosticsCategoryPill(
                                category: category,
                                count: count,
                                isSelected: selectedCategory == category
                            ) {
                                if selectedCategory == category {
                                    selectedCategory = nil
                                } else {
                                    selectedCategory = category
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var filteredRecords: [AppErrorRecord] {
        guard let category = selectedCategory else { return records }
        return records.filter { $0.category == category }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await copyBundleToClipboard() }
                } label: {
                    Label("Copy diagnostic bundle", systemImage: "doc.on.clipboard")
                }
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("Clear log", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        let snapshot = await AppErrorRecorder.shared.snapshot()
        let countsSnapshot = await AppErrorRecorder.shared.counts()
        records = snapshot
        counts = countsSnapshot
    }

    /// Build a redacted text bundle the user can paste into a support
    /// thread / GitHub issue. Same posture as the existing relay
    /// diagnostics export — local-only, never auto-uploaded.
    private func copyBundleToClipboard() async {
        let bundle = Self.makeBundle(from: records)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundle, forType: .string)
        #else
        UIPasteboard.general.string = bundle
        #endif
    }

    static func makeBundle(from records: [AppErrorRecord]) -> String {
        let header = """
        # Reolens diagnostic bundle
        # \(records.count) record\(records.count == 1 ? "" : "s")
        # Local to this device — Reolens never uploads this.
        """
        let lines = records.map { record -> String in
            let dateString = ISO8601DateFormatter().string(from: record.timestamp)
            let context = record.context.map { " [\($0)]" } ?? ""
            return "\(dateString) \(record.category.rawValue)\(context): \(record.detail)"
        }
        return ([header] + lines).joined(separator: "\n")
    }
}

// MARK: - Row

private struct DiagnosticsErrorRow: View {
    let record: AppErrorRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                Text(record.category.rawValue.capitalized)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(record.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let userMessage = record.userMessage {
                Text(userMessage)
                    .font(.body)
            }
            Text(record.detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let context = record.context {
                Text(context)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        switch record.category {
        case .network, .streaming: "wifi.exclamationmark"
        case .auth: "key.fill"
        case .playback: "play.slash.fill"
        case .persistence: "externaldrive.badge.exclamationmark"
        case .notification: "bell.slash"
        case .schedule: "calendar.badge.exclamationmark"
        case .bookmark: "bookmark.slash"
        case .other: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch record.category {
        case .network, .streaming, .auth, .playback: .red
        case .notification, .persistence: .orange
        case .schedule, .bookmark: .yellow
        case .other: .secondary
        }
    }

    private var accessibilityLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let timeString = formatter.string(from: record.timestamp)
        let message = record.userMessage ?? record.detail
        return "\(record.category.rawValue) error at \(timeString): \(message)"
    }
}

// MARK: - Category pill

private struct DiagnosticsCategoryPill: View {
    let category: AppError.Category
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(category.rawValue.capitalized)
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.rawValue) — \(count) record\(count == 1 ? "" : "s"). \(isSelected ? "Selected. Tap to clear filter." : "Tap to filter.")")
    }
}

import SwiftUI

/// 0.5.0 Theme A5 — read-only sheet showing yesterday's overnight
/// digest. Cross-platform: hosted from `ReolensApp` on macOS via the
/// `pendingIntentNavigation == .digest(day:)` path, from
/// `ReolensiOSApp` via the same. Source data is the most-recent
/// `DailyDigestRecord` in `<AppGroup>/digests/` — written by
/// `DigestScheduler.runDigest(...)`.
public struct DigestDetailView: View {

    /// The day to render. When nil, falls back to
    /// `SharedContainer.readMostRecentDigest()` so the sheet
    /// gracefully renders the latest digest if the requested day
    /// wasn't built (e.g. user tapped a notification before the
    /// scheduler had a chance to run).
    public let requestedDay: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var digest: SharedContainer.DailyDigestRecord?

    public init(requestedDay: Date? = nil) {
        self.requestedDay = requestedDay
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let digest {
                    content(digest: digest)
                } else {
                    emptyState
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 480, minHeight: 420, idealHeight: 580)
        .task {
            digest = SharedContainer.readMostRecentDigest()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overnight digest")
                    .font(.title3.weight(.semibold))
                if let digest {
                    Text(digest.day, format: .dateTime.weekday(.wide).month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .reolensGlassPanel()
    }

    @ViewBuilder
    private func content(digest: SharedContainer.DailyDigestRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            headline(digest: digest)
            if !digest.hourlyBuckets.isEmpty {
                hourlyChart(buckets: digest.hourlyBuckets, peakHour: digest.peakHour)
            }
            if !digest.perCameraCounts.isEmpty {
                perCameraSection(counts: digest.perCameraCounts)
            }
            if !digest.perTagCounts.isEmpty {
                perTagSection(counts: digest.perTagCounts)
            }
        }
        .padding(16)
    }

    private func headline(digest: SharedContainer.DailyDigestRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(digest.totalEvents)")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(digest.totalEvents == 1 ? "motion event" : "motion events")
                .font(.callout)
                .foregroundStyle(.secondary)
            if digest.totalEvents > 0 {
                Text("Peak activity at \(digest.peakHour):00")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .reolensGlassCard()
    }

    private func hourlyChart(buckets: [Int], peakHour: Int) -> some View {
        let maxCount = max(buckets.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("By hour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(hour == peakHour ? Color.accentColor : Color.accentColor.opacity(0.45))
                            .frame(height: max(2, CGFloat(buckets[hour]) / CGFloat(maxCount) * 60))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(" ")
                                .font(.system(size: 8))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 80)
        }
        .padding(12)
        .reolensGlassCard()
    }

    private func perCameraSection(counts: [SharedContainer.DailyDigestRecord.PerCameraCount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per camera")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(counts, id: \.cameraName) { row in
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                    Text(row.cameraName)
                        .font(.callout)
                    Spacer()
                    Text("\(row.count)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .reolensGlassCard()
    }

    private func perTagSection(counts: [String: Int]) -> some View {
        let sorted = counts.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("By detection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(sorted, id: \.key) { entry in
                    HStack(spacing: 4) {
                        Text(entry.key.capitalized)
                            .font(.caption.weight(.medium))
                        Text("\(entry.value)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .reolensGlassChip()
                }
                Spacer()
            }
        }
        .padding(12)
        .reolensGlassCard()
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No digest yet",
            systemImage: "moon.zzz",
            description: Text("Your overnight digest will appear here once the scheduler has run at least once.")
        )
        .padding(48)
    }
}

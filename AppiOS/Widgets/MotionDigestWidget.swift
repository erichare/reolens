import WidgetKit
import SwiftUI
import AppShared

/// Home Screen widget showing last night's motion digest: total
/// events, top-3 cameras, hourly sparkline. Built from the most-
/// recent `DailyDigestRecord` written by `DigestBuilder`. Refreshes
/// after the daily-digest task fires (the main app calls
/// `WidgetCenter.shared.reloadTimelines(ofKind:)`). AGENTS.md §16.
public struct MotionDigestWidget: Widget {

    public static let kind = "io.reolens.widget.motionDigest"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: MotionDigestProvider()
        ) { entry in
            MotionDigestView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Overnight Digest")
        .description("Yesterday's motion-event summary across your cameras.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

public struct MotionDigestEntry: TimelineEntry {
    public let date: Date
    public let digest: SharedContainer.DailyDigestRecord?

    public init(date: Date, digest: SharedContainer.DailyDigestRecord?) {
        self.date = date
        self.digest = digest
    }
}

public struct MotionDigestProvider: TimelineProvider {
    public typealias Entry = MotionDigestEntry

    public init() {}

    public func placeholder(in context: Context) -> MotionDigestEntry {
        MotionDigestEntry(date: .now, digest: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping @Sendable (MotionDigestEntry) -> Void) {
        completion(MotionDigestEntry(date: .now, digest: SharedContainer.readMostRecentDigest()))
    }

    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<MotionDigestEntry>) -> Void) {
        let entry = MotionDigestEntry(date: .now, digest: SharedContainer.readMostRecentDigest())
        // Refresh hourly so the relative "yesterday" framing stays
        // current; main app will trigger a forced reload after the
        // daily digest task fires.
        let next = Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct MotionDigestView: View {
    let entry: MotionDigestEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill")
                Text("Overnight digest")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let digest = entry.digest {
                    Text("\(digest.totalEvents)")
                        .font(.title2.weight(.bold))
                }
            }

            if let digest = entry.digest {
                ForEach(Array(digest.perCameraCounts.prefix(3)), id: \.cameraName) { row in
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(row.cameraName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(row.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                SparklineView(buckets: digest.hourlyBuckets)
                    .frame(height: 24)
            } else {
                Text("No events overnight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

struct SparklineView: View {
    let buckets: [Int]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(buckets.max() ?? 1, 1)
            let stepX = proxy.size.width / CGFloat(max(buckets.count - 1, 1))
            Path { path in
                for (index, value) in buckets.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = proxy.size.height * (1 - CGFloat(value) / CGFloat(maxValue))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}

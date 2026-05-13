import WidgetKit
import SwiftUI
import AppShared

/// Lock Screen widget: which camera fired most recently + how long
/// ago. Reads `RecentMotionEvents.plist` from the App Group; no
/// network, no Keychain. AGENTS.md §16.
public struct LastMotionWidget: Widget {

    public static let kind = "io.reolens.widget.lastMotion"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: LastMotionProvider()
        ) { entry in
            LastMotionView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Last Motion")
        .description("Which camera fired most recently.")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

public struct LastMotionEntry: TimelineEntry {
    public let date: Date
    public let cameraName: String
    public let firedAt: Date?

    public init(date: Date, cameraName: String, firedAt: Date?) {
        self.date = date
        self.cameraName = cameraName
        self.firedAt = firedAt
    }
}

public struct LastMotionProvider: TimelineProvider {
    public typealias Entry = LastMotionEntry

    public init() {}

    public func placeholder(in context: Context) -> LastMotionEntry {
        LastMotionEntry(date: .now, cameraName: "Front Door", firedAt: .now.addingTimeInterval(-120))
    }

    public func getSnapshot(in context: Context, completion: @escaping @Sendable (LastMotionEntry) -> Void) {
        completion(Self.makeEntry())
    }

    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LastMotionEntry>) -> Void) {
        let entry = Self.makeEntry()
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func makeEntry() -> LastMotionEntry {
        let last = SharedContainer.readRecentMotionEvents().first
        return LastMotionEntry(
            date: .now,
            cameraName: last?.cameraName ?? "No events",
            firedAt: last?.timestamp
        )
    }
}

struct LastMotionView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LastMotionEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let firedAt = entry.firedAt {
                Text("\(entry.cameraName) · \(firedAt, format: .relative(presentation: .named))")
            } else {
                Text(entry.cameraName)
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "video.fill")
                        .font(.title3)
                    if let firedAt = entry.firedAt {
                        Text(firedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.cameraName, systemImage: "video.fill")
                    .font(.headline)
                    .lineLimit(1)
                if let firedAt = entry.firedAt {
                    Text(firedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No recent motion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

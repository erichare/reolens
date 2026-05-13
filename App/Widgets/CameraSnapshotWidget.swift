import WidgetKit
import SwiftUI
import AppKit
import AppShared

/// 0.5.0 Theme A1 (macOS twin) — desktop widget showing the latest
/// cached snapshot from one camera + the last-motion timestamp.
/// Reads everything from the App-Group container — no network, no
/// Keychain. AGENTS.md §16.
///
/// The body of this widget mirrors `AppiOS/Widgets/CameraSnapshotWidget.swift`
/// almost verbatim; the only platform difference is `NSImage`
/// vs. `UIImage` for the underlying snapshot bytes.
public struct CameraSnapshotWidget: Widget {

    public static let kind = "io.reolens.widget.cameraSnapshot"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: SelectCameraIntent.self,
            provider: CameraSnapshotProvider()
        ) { entry in
            CameraSnapshotView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Camera Snapshot")
        .description("Latest snapshot from a Reolink camera, with the last motion event.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

public struct CameraSnapshotEntry: TimelineEntry {
    public let date: Date
    public let cameraID: UUID?
    public let cameraName: String
    public let snapshotImageData: Data?
    public let lastMotionAt: Date?

    public init(
        date: Date,
        cameraID: UUID?,
        cameraName: String,
        snapshotImageData: Data?,
        lastMotionAt: Date?
    ) {
        self.date = date
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.snapshotImageData = snapshotImageData
        self.lastMotionAt = lastMotionAt
    }
}

public struct CameraSnapshotProvider: AppIntentTimelineProvider {
    public typealias Entry = CameraSnapshotEntry
    public typealias Intent = SelectCameraIntent

    public init() {}

    public func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(
            date: .now,
            cameraID: nil,
            cameraName: "Front Door",
            snapshotImageData: nil,
            lastMotionAt: nil
        )
    }

    public func snapshot(for configuration: SelectCameraIntent, in context: Context) async -> CameraSnapshotEntry {
        Self.makeEntry(for: configuration)
    }

    public func timeline(for configuration: SelectCameraIntent, in context: Context) async -> Timeline<CameraSnapshotEntry> {
        let entry = Self.makeEntry(for: configuration)
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private static func makeEntry(for configuration: SelectCameraIntent) -> CameraSnapshotEntry {
        let snapshots = SharedContainer.readLatestSnapshots()
        let snapshot = snapshots.first(where: { $0.cameraID == configuration.camera?.id })
            ?? snapshots.first
        let imageData: Data? = {
            guard let path = snapshot?.imageRelativePath,
                  let dir = SharedContainer.snapshotImagesDirectory
            else { return nil }
            return try? Data(contentsOf: dir.appending(path: path))
        }()
        return CameraSnapshotEntry(
            date: .now,
            cameraID: snapshot?.cameraID,
            cameraName: snapshot?.cameraName ?? "No Camera",
            snapshotImageData: imageData,
            lastMotionAt: snapshot?.lastMotionAt
        )
    }
}

struct CameraSnapshotView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let data = entry.snapshotImageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.cameraName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let last = entry.lastMotionAt {
                    Text(last, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }
}

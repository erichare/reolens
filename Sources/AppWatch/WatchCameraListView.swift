#if !os(macOS)
import SwiftUI

/// Flat list of cameras the iPhone is publishing snapshots for.
/// Multi-channel hubs surface as one row per channel — the watch's
/// tiny screen + crown UI works better with shallow lists than
/// nested disclosure groups.
///
/// Tapping a row pushes the live view for that camera+channel.
struct WatchCameraListView: View {
    @State private var snapshots: [WatchSharedContainer.LatestSnapshot] = []
    /// Modification timestamp of the snapshots plist — used to skip
    /// re-decoding on a tick when nothing has changed.
    @State private var lastModified: Date?

    var body: some View {
        Group {
            if snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No cameras yet", systemImage: "video.slash")
                } description: {
                    Text("Open Reolens on your iPhone to publish snapshots to your watch.")
                        .multilineTextAlignment(.center)
                }
            } else {
                List(snapshots) { snap in
                    NavigationLink {
                        WatchLiveView(cameraID: snap.cameraID, channel: snap.channel, cameraName: snap.cameraName)
                    } label: {
                        WatchCameraRow(snapshot: snap)
                    }
                }
                .listStyle(.carousel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WatchRecordingsView()
                } label: {
                    Label("Recordings", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .task(id: tickIdentifier) {
            // Periodic re-read of the App Group container so newly
            // added cameras and refreshed snapshots show up without
            // requiring the user to background and re-foreground the
            // watch app. Uses the file's mtime as a cheap "did
            // anything change?" check before re-decoding.
            await pollSnapshotsListUntilCancelled()
        }
    }

    private var tickIdentifier: String { "snapshot-list" }

    private func pollSnapshotsListUntilCancelled() async {
        while !Task.isCancelled {
            let mtime = WatchSharedContainer.Reader.snapshotsLastModified()
            if mtime != lastModified {
                lastModified = mtime
                snapshots = WatchSharedContainer.Reader.readLatestSnapshots()
                    .sorted { lhs, rhs in
                        // Stable sort: most-recent activity first,
                        // ties broken by name for determinism.
                        let lActivity = lhs.lastMotionAt ?? lhs.lastUpdated
                        let rActivity = rhs.lastMotionAt ?? rhs.lastUpdated
                        if lActivity != rActivity { return lActivity > rActivity }
                        return lhs.cameraName < rhs.cameraName
                    }
            }
            // 5s is plenty for the list view — live polling is faster,
            // but the camera list itself rarely changes second-by-second.
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// One row in the camera list: snapshot thumbnail + camera/channel
/// name + relative "last motion" timestamp.
private struct WatchCameraRow: View {
    let snapshot: WatchSharedContainer.LatestSnapshot

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 50, height: 32)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.cameraName)
                    .font(.headline)
                    .lineLimit(1)
                if let motion = snapshot.lastMotionAt {
                    Text(motion, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = snapshot.imageURL,
           let data = try? Data(contentsOf: url),
           let image = imageFromData(data) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "video.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// Decode a JPEG into a SwiftUI `Image`. Kept as a function to
    /// localize the platform-conditional UIImage/NSImage bridging
    /// behind a single helper.
    private func imageFromData(_ data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#endif

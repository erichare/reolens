#if !os(macOS)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// "Live" view for one camera. The watch v1 doesn't fetch directly
/// from the camera (cross-device Keychain Sharing for credentials is
/// a separate piece of plumbing). Instead it polls the App Group
/// container at the configured cadence — whenever the iPhone refreshes
/// its widget snapshot, the watch picks it up.
///
/// Polling automatically pauses on wrist-down (the SwiftUI scene phase
/// transitions to `.inactive`) and on view dismiss (the `.task`
/// modifier cancels when the navigation pops).
struct WatchLiveView: View {
    let cameraID: UUID
    let channel: Int
    let cameraName: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: WatchSharedContainer.LatestSnapshot?
    @State private var jpegData: Data?
    @State private var lastImageMTime: Date?

    /// 2.0s — matches the agreed v1 cadence. Faster cadence isn't
    /// useful here because the underlying data only updates as fast
    /// as the iPhone refreshes its widget pipeline. If we move to
    /// direct-from-watch polling later, this constant tunes that.
    private static let pollCadence: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 6) {
            imageView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let snapshot {
                Text(snapshot.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle(cameraName)
        .task(id: scenePhase) {
            // `.task(id: scenePhase)` re-runs whenever scene phase
            // changes — including wrist-down → wrist-up. The previous
            // body's cancellation handles wrist-down auto-pause for
            // free without explicit timer teardown.
            guard scenePhase == .active else { return }
            await pollUntilCancelled()
        }
    }

    @ViewBuilder
    private var imageView: some View {
        if let jpegData, let image = imageFromData(jpegData) {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // First-load placeholder; replaced on the first successful
            // read from the App Group container.
            VStack(spacing: 4) {
                ProgressView()
                Text("Waiting for iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pollUntilCancelled() async {
        while !Task.isCancelled {
            refreshOnce()
            try? await Task.sleep(for: Self.pollCadence)
        }
    }

    /// Re-read the snapshots plist and JPEG file for this camera.
    /// Cheap path: uses the JPEG file's mtime to skip a re-read when
    /// the iPhone hasn't published a new frame.
    private func refreshOnce() {
        let all = WatchSharedContainer.Reader.readLatestSnapshots()
        let match = all.first { $0.cameraID == cameraID && $0.channel == channel }
        snapshot = match
        guard let url = match?.imageURL else {
            jpegData = nil
            return
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if mtime != lastImageMTime {
            lastImageMTime = mtime
            jpegData = try? Data(contentsOf: url)
        }
    }

    private func imageFromData(_ data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}
#endif

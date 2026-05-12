import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftUI view that renders the cached preview snapshot for a camera
/// channel, refreshing it on appear if the file is missing or stale.
///
/// Used by both the macOS `LiveCameraTile` and the iOS `LiveTileView`
/// when they're in "preview mode" — i.e. the user has not opted into
/// live-streaming the grid (0.4.0 default). Reads bytes synchronously
/// from `CameraPreviewService` so SwiftUI gets an immediate first frame
/// when a cached file exists; if it's missing or older than
/// `staleThreshold`, an async refresh is kicked off via the camera's
/// `cmd=Snap` URL.
public struct CameraPreviewImage: View {
    public let cameraID: UUID
    public let cameraName: String
    public let channel: Int
    /// Provider for the camera's `cmd=Snap` URL — the closure is
    /// `@MainActor` because it reads `CameraSession` state. May return
    /// nil if the session isn't authenticated yet; the view will retry
    /// on next appear.
    public let snapshotURLProvider: @Sendable () async -> URL?
    /// Optional preparation step run before the first `cmd=Snap` fetch
    /// — used to wake battery / sleeping cameras via Baichuan so the
    /// snapshot endpoint actually has a live camera to respond from.
    /// nil for camera types that don't need waking; the service just
    /// proceeds straight to the HTTP fetch.
    public let prepareForFetch: (@Sendable () async -> Void)?
    /// When true, the cached snapshot center-crops to fill the cell
    /// (`.fill` + `.clipped`). Used by grids with uniform-aspect cells
    /// (e.g. fixed 2×2 / 3×3 / 4×4) when the camera's native frame is
    /// wider than the cell — letterboxing a 32:9 dual-lens snapshot in
    /// a 16:9 cell produces a thin horizontal strip with huge black
    /// bars, which users perceived as a layout bug. Default false so
    /// adaptive grids (which give dual-lens its own 32:9 cell) keep
    /// the full stitched frame visible.
    public var centerCrop: Bool = false
    /// How old a cached preview can be before we auto-refresh on appear.
    /// Default is 30 minutes — the user can pull-to-refresh sooner.
    public var staleThreshold: TimeInterval = 30 * 60

    @State private var data: Data?
    @State private var capturedAt: Date?
    @State private var isLoading: Bool = false

    public init(
        cameraID: UUID,
        cameraName: String,
        channel: Int,
        snapshotURLProvider: @escaping @Sendable () async -> URL?,
        prepareForFetch: (@Sendable () async -> Void)? = nil,
        centerCrop: Bool = false,
        staleThreshold: TimeInterval = 30 * 60
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.channel = channel
        self.snapshotURLProvider = snapshotURLProvider
        self.prepareForFetch = prepareForFetch
        self.centerCrop = centerCrop
        self.staleThreshold = staleThreshold
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let data, let image = Image(jpegData: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: centerCrop ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
            }
            if let capturedAt {
                freshnessOverlay(for: capturedAt)
            } else if isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(8)
            }
        }
        // Hard outer clip so nothing — image, freshness overlay, or
        // future additions — can spill into adjacent cells regardless
        // of what an ancestor view does with its frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: cameraID) {
            await load()
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.fill")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No preview yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func freshnessOverlay(for capturedAt: Date) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "clock")
                .font(.caption2)
            Text(relativeLabel(for: capturedAt))
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func relativeLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Load the cached data synchronously, then decide whether to refresh.
    private func load() async {
        let initial = CameraPreviewService.shared.cachedData(cameraID: cameraID, channel: channel)
        let mod = CameraPreviewService.shared.cachedAt(cameraID: cameraID, channel: channel)
        await MainActor.run {
            self.data = initial
            self.capturedAt = mod
        }
        let shouldRefresh: Bool = {
            guard let mod else { return true }
            return Date().timeIntervalSince(mod) > staleThreshold
        }()
        if shouldRefresh {
            await refresh()
        }
    }

    /// Public-ish refresh entry point — also called by the parent on
    /// pull-to-refresh via `CameraPreviewService.shared` directly.
    public func refresh() async {
        await MainActor.run { self.isLoading = true }
        defer { Task { @MainActor in self.isLoading = false } }
        // Wake battery / sleeping cameras before hitting cmd=Snap.
        // The Reolink JPEG endpoint returns either nothing or a stale
        // frame when the camera is asleep at the radio layer; waking
        // first via Baichuan gives us a live frame within a second.
        await prepareForFetch?()
        guard let url = await snapshotURLProvider() else { return }
        let newData = await CameraPreviewService.shared.refresh(
            snapshotURL: url,
            cameraID: cameraID,
            channel: channel
        )
        await MainActor.run {
            if let newData {
                self.data = newData
                self.capturedAt = Date()
            }
        }
    }
}

extension Image {
    /// Cross-platform `Image` initializer from raw JPEG/PNG bytes. Uses
    /// the right system image type per platform — there's no single
    /// SwiftUI initializer that takes `Data` directly, so we go through
    /// `UIImage` or `NSImage` depending on what's compiled in.
    init?(jpegData data: Data) {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return nil }
        self.init(uiImage: img)
        #elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return nil }
        self.init(nsImage: img)
        #else
        return nil
        #endif
    }
}

import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "recordings.player")

/// 0.6.2 — extracted from `App/Views/RecordingsView.swift` so the
/// parent file shrinks under the 800-LOC repo guideline. Hosts the
/// macOS recording-playback sheet + its supporting data type
/// (`PlayableRecording`), the small `RawResponseView` debug helper,
/// and the AVKit `NSViewRepresentable` bridge. No behavior change.
struct PlayableRecording: Identifiable, Hashable {
    let file: SearchFile
    let url: URL
    let isHighQuality: Bool
    /// If non-nil, the recording is being downloaded to this user-chosen
    /// path rather than previewed in-app. The sheet still surfaces progress
    /// but moves the file to this destination on completion instead of
    /// auto-playing it.
    let saveDestination: URL?
    /// 0.5.0 Theme C1 — when non-nil, indicates the user is exporting
    /// a bookmarked sub-range of the source file. Times are relative
    /// to the source file's start in seconds. The player sheet's
    /// post-download hook runs `ClipExporter.export(...)` against
    /// this range before moving the result to `saveDestination`.
    let bookmarkTrim: ClosedRange<TimeInterval>?

    init(
        file: SearchFile,
        url: URL,
        isHighQuality: Bool,
        saveDestination: URL? = nil,
        bookmarkTrim: ClosedRange<TimeInterval>? = nil
    ) {
        self.file = file
        self.url = url
        self.isHighQuality = isHighQuality
        self.saveDestination = saveDestination
        self.bookmarkTrim = bookmarkTrim
    }

    var id: String { file.name }
    var isSaving: Bool { saveDestination != nil }
}

struct RecordingPlayerSheet: View {
    let recording: PlayableRecording
    @Environment(\.dismiss) private var dismiss
    @State private var downloader = RecordingDownloader()
    @State private var startedAt: Date?
    /// True once the save-to-disk move has finished. We keep the sheet open
    /// for a moment afterward so the user sees the "done" state.
    @State private var saveCompletedAt: URL?
    @State private var saveError: String?
    /// 0.5.0 Theme A3 — captured `AVPlayer` from the host view, used
    /// to drive the custom `ScrubberView` underneath. Stays nil
    /// until the AVPlayer is created in `AVPlayerHostView.makeNSView`.
    @State private var activePlayer: AVPlayer?
    @State private var assetDurationSeconds: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 800, idealHeight: 540)
        .task(id: recording.id) {
            startedAt = Date()
            downloader.start(url: recording.url)
        }
        .onChange(of: downloader.state) { _, new in
            if case .ready = new, let dest = recording.saveDestination, saveCompletedAt == nil {
                moveToSaveDestination(dest: dest)
            }
        }
        .onDisappear {
            downloader.cancel()
            // The downloader's cache promotes successful downloads
            // into ~/Library/Caches/Reolens/recordings/ — re-tapping
            // the same recording later is a cache hit. cleanupTempFile
            // is now cache-aware (no-op for cached files), but skipping
            // the call entirely keeps intent obvious.
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.file.name).font(.headline)
                HStack(spacing: 6) {
                    if let start = recording.file.startDate {
                        Text(start, format: .dateTime.day().month().year().hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(recording.isHighQuality ? "High quality (main)" : "Low quality (sub)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(recording.isHighQuality ? .blue : .secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch downloader.state {
        case .idle, .downloading:
            downloadingPanel
        case .ready:
            if let saveError {
                ContentUnavailableView {
                    Label("Couldn't save recording", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(saveError).font(.caption).textSelection(.enabled)
                }
            } else if recording.isSaving, let dest = saveCompletedAt {
                savedPanel(at: dest)
            } else if recording.isSaving {
                downloadingPanel
            } else if let localURL = downloader.localURL {
                VStack(spacing: 0) {
                    AVPlayerHostView(url: localURL) { player in
                        activePlayer = player
                        Task {
                            let asset = AVURLAsset(url: localURL)
                            if let dur = try? await asset.load(.duration) {
                                assetDurationSeconds = CMTimeGetSeconds(dur)
                            }
                        }
                    }
                    .frame(minWidth: 720, minHeight: 405)
                    // 0.5.0 Theme A3 — custom scrubber with the
                    // thumbnail rail. Sits below the native AVPlayer
                    // view; the native controls stay visible as a
                    // fallback so users with VoiceOver or other
                    // accessibility tools always have native chrome.
                    if let activePlayer, assetDurationSeconds > 0 {
                        ScrubberView(
                            player: activePlayer,
                            segmentID: recording.file.name,
                            durationSeconds: assetDurationSeconds
                        )
                    }
                }
            } else {
                downloadingPanel
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(recording.isSaving ? "Couldn't download recording" : "Couldn't play this recording", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.caption).textSelection(.enabled)
            } actions: {
                Button("Retry") { downloader.start(url: recording.url) }
            }
        }
    }

    private func savedPanel(at dest: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Saved").font(.headline)
            Text(dest.lastPathComponent)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func moveToSaveDestination(dest: URL) {
        guard let localURL = downloader.localURL else {
            saveError = "Download completed but no local file was produced."
            return
        }
        // 0.5.0 Theme C1 — bookmark export path: trim the downloaded
        // file to the bookmark's range before placing at the user's
        // destination. The plain "Download High Quality" path
        // (`bookmarkTrim == nil`) skips this and just moves the
        // file as-is, preserving the original behavior.
        if let trim = recording.bookmarkTrim {
            Task { @MainActor in
                do {
                    try await ClipExporter.export(
                        sources: [.init(url: localURL, range: trim)],
                        to: dest
                    )
                    // The exporter writes directly to `dest`. Remove
                    // the (now redundant) temp file so we don't leave
                    // multi-hundred-MB downloads on disk.
                    try? FileManager.default.removeItem(at: localURL)
                    saveCompletedAt = dest
                } catch {
                    saveError = "Couldn't trim & export: \(error.localizedDescription)"
                }
            }
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: localURL, to: dest)
            saveCompletedAt = dest
        } catch {
            saveError = "Couldn't move to \(dest.path): \(error.localizedDescription)"
        }
    }

    private var downloadingPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Downloading recording…").font(.headline)
            // The Search response's `size` is the authoritative file size on
            // disk — prefer it over the downloader's running total. The
            // downloader bumps its `totalBytes` to match `bytesReceived` when
            // the server omits `Content-Length` (which Reolink Home Hub Pro
            // does on this endpoint), so without this anchor the progress
            // bar reads as ~100% throughout the download.
            let received = downloader.bytesReceived
            let expected = recording.file.size.map(Int64.init) ?? 0
            let total = max(expected, downloader.totalBytes, received)
            if total > 0 {
                let progress = min(1.0, Double(received) / Double(total))
                ProgressView(value: progress).frame(width: 280)
                HStack(spacing: 6) {
                    Text("\(byteFormatter.string(fromByteCount: received)) / \(byteFormatter.string(fromByteCount: total))")
                    if let rate = throughput {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(byteFormatter.string(fromByteCount: rate))/s")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if received > 0 {
                Text(byteFormatter.string(fromByteCount: received))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var throughput: Int64? {
        guard let startedAt, downloader.bytesReceived > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else { return nil }
        return Int64(Double(downloader.bytesReceived) / elapsed)
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }
}

/// Popover that shows the raw JSON response from the camera and lets the
/// user copy it. Use to diagnose why detection icons don't match.
struct RawResponseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Raw Search response").font(.headline)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    // 0.6.2 a11y — switched from a fixed 11pt size
                    // so the raw-JSON viewer respects Dynamic Type.
                    // Still monospaced for code-like readability.
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
            // 0.5.0 Liquid Glass — raw-JSON popover card.
            .reolensGlassCard()
            .clipShape(.rect(cornerRadius: 6))
        }
        .padding(12)
    }
}

/// macOS AVPlayer host that auto-plays the URL when shown.
struct AVPlayerHostView: NSViewRepresentable {
    let url: URL
    /// 0.5.0 Theme A3 — when non-nil, the host writes the active
    /// `AVPlayer` here so the surrounding sheet can drive its own
    /// custom scrubber (`ScrubberView`) against the same playback
    /// instance. Native controls also stay visible for fallback.
    let playerSink: ((AVPlayer) -> Void)?

    init(url: URL, playerSink: ((AVPlayer) -> Void)? = nil) {
        self.url = url
        self.playerSink = playerSink
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        playerSink?(player)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url, current != url {
            let player = AVPlayer(url: url)
            nsView.player = player
            player.play()
            playerSink?(player)
        }
    }
}

import SwiftUI
import OSLog
import ReolinkAPI
import ReolinkStreaming
#if canImport(AVKit)
import AVKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "all-recordings.subviews")

/// 0.6.2 — extracted from `Sources/AppShared/AllRecordingsView.swift`
/// to start the file-decomposition ratchet. Hosts the three trailing
/// sub-views the parent file used to define inline:
///
/// - `TodayDigestRow` — the today's-digest banner row.
/// - `RecordingPreviewSheet` — the preview sheet for tapping a row.
/// - `AVPlayerStreamView` — the AVKit bridge used by the preview sheet.
///
/// All three were `fileprivate`-equivalent (no `public`) in the
/// original; here they're declared `internal` so the parent file can
/// reference them across the module boundary. No behavior change.
/// 0.5.1 — Inline digest row shown at the top of `AllRecordingsView`
/// when the current day is being browsed. Tries on-device
/// FoundationModels first; falls back to a deterministic count-based
/// summary otherwise. Either way, this is purely on-device — no
/// network calls. The `source` chip lets the user see at a glance
/// whether they're looking at the AI-generated text or the basic
/// fallback.
internal struct TodayDigestRow: View {
    let digest: EventSummarizer.DailyDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: digest.source == .foundationModels ? "sparkles" : "chart.bar.doc.horizontal")
                    .foregroundStyle(.tint)
                Text(digest.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
            }
            if !digest.bulletPoints.isEmpty {
                ForEach(digest.bulletPoints, id: \.self) { line in
                    Text("• \(line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today's digest: \(digest.headline)")
    }
}

/// Cross-platform preview sheet for the All Recordings list.
///
/// For HTTP URLs (camera CGI `cmd=Download`) we route through
/// `RecordingDownloader` first: AVPlayer's progressive-HTTP code path
/// gives up on Reolink's CGI response (no `Accept-Ranges`, omitted
/// `Content-Type`, no `Content-Length` on Home Hub Pro) and renders
/// a slashed-player icon. Downloading the whole clip to a cache file
/// first and then handing that local URL to `AVPlayer` always works
/// and is a no-op on the second tap thanks to the downloader's
/// content-stable disk cache.
///
/// For `file://` URLs we play directly — the bookmark path passes a
/// local file that's already on disk.
internal struct RecordingPreviewSheet: View {
    let url: URL
    let title: String
    let onDismiss: () -> Void

    @State private var downloader = RecordingDownloader()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Close", action: onDismiss).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: url) {
            // Local files (already-downloaded bookmarks) play
            // directly; only remote CGI URLs go through the
            // downloader.
            if !url.isFileURL {
                downloader.start(url: url)
            }
        }
        .onDisappear { downloader.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(AVKit)
        if url.isFileURL {
            AVPlayerStreamView(url: url)
                .frame(minWidth: 480, minHeight: 270)
        } else {
            switch downloader.state {
            case .idle, .downloading:
                downloadingPanel
            case .ready:
                if let localURL = downloader.localURL {
                    AVPlayerStreamView(url: localURL)
                        .frame(minWidth: 480, minHeight: 270)
                } else {
                    ContentUnavailableView("Couldn't open clip", systemImage: "play.slash")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't play this recording", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.caption).textSelection(.enabled)
                } actions: {
                    Button("Retry") { downloader.start(url: url) }
                }
            }
        }
        #else
        ContentUnavailableView("Playback unavailable", systemImage: "play.slash")
        #endif
    }

    private var downloadingPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Loading recording…").font(.headline)
            let received = downloader.bytesReceived
            let total = max(downloader.totalBytes, received)
            if total > 0 {
                ProgressView(value: min(1.0, Double(received) / Double(max(total, 1))))
                    .frame(maxWidth: 320)
                Text("\(byteString(received)) of \(byteString(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.regular)
                Text("Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

#if canImport(AVKit)
import AVKit

internal struct AVPlayerStreamView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let item = AVPlayerItem(url: url)
                let p = AVPlayer(playerItem: item)
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}
#endif

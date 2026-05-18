import SwiftUI
import OSLog
import ReolinkAPI
import ReolinkStreaming

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

// 0.7.0 — `RecordingPreviewSheet` and its embedded
// `AVPlayerStreamView` lived here as a third, lower-fidelity playback
// surface (no quality switching, no export, full-download-before-
// play). The shared `RecordingPlayerSheet` in
// `Sources/AppShared/Playback/` replaces it; both AllRecordings and
// per-camera lists now flow through one path.

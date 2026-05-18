import SwiftUI

/// Header row for the shared `RecordingPlayerSheet`. Renders the
/// title, the quality picker (segmented control when the recording
/// has both variants, label-only otherwise), and the Export menu
/// that dispatches to the platform-native destinations.
///
/// Bound to the engine so quality changes propagate through one
/// path. Export actions surface through closures the parent sheet
/// owns — the controls don't know about export staging, they just
/// fire user intent.
struct RecordingPlayerHeader: View {

    @Bindable var engine: RecordingPlaybackEngine

    let recording: PlayableRecording
    let onExport: (RecordingExportDestination) -> Void
    let onDismiss: () -> Void

    let startedAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(recording.cameraName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let start = recording.startDate {
                        Text("·").foregroundStyle(.tertiary)
                        Text(start, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let streamingLine = streamingStatusLine {
                        Text("·").foregroundStyle(.tertiary)
                        Text(streamingLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Streaming progress: \(streamingLine)")
                    }
                }
            }
            Spacer(minLength: 12)
            qualityControl
            exportMenu
            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Compact "received / total · rate/s" line that stays visible
    /// in the header during streaming. Disappears once the engine
    /// reports the full file is cached, because there's no longer
    /// anything to report.
    private var streamingStatusLine: String? {
        if engine.isFullyCached { return nil }
        let received = engine.bytesReceived
        guard received > 0 else { return nil }
        let total = max(engine.totalBytes, received)
        let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let totalStr = total > received
            ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            : nil
        let rateStr = throughputString
        var parts: [String] = []
        if let totalStr {
            parts.append("\(receivedStr) / \(totalStr)")
        } else {
            parts.append(receivedStr)
        }
        if let rateStr { parts.append(rateStr) }
        return parts.joined(separator: " · ")
    }

    private var throughputString: String? {
        guard let startedAt, engine.bytesReceived > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else { return nil }
        let rate = Int64(Double(engine.bytesReceived) / elapsed)
        return "\(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s"
    }

    private var headerTitle: String {
        if let start = recording.startDate {
            return start.formatted(date: .abbreviated, time: .shortened)
        }
        return recording.displayName
    }

    @ViewBuilder
    private var qualityControl: some View {
        if recording.canSwitchQuality {
            Picker("Quality", selection: Binding(
                get: { engine.currentQuality },
                set: { engine.switchQuality(to: $0) }
            )) {
                ForEach(recording.availableQualities, id: \.self) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 160)
            .help("Switch between low and high quality. Playback resumes at the same time.")
        } else if let only = recording.availableQualities.first {
            // Single-quality clip: show the label so the user knows
            // what they're getting instead of a disabled picker that
            // reads as "the toggle is broken".
            Text(only.longLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(RecordingExportDestination.available) { destination in
                Button {
                    onExport(destination)
                } label: {
                    Label(destination.label, systemImage: destination.systemImage)
                }
                .disabled(!engine.isFullyCached && destination == .photos)
                .help(destination == .photos && !engine.isFullyCached
                      ? "Save to Photos becomes available once the full clip downloads."
                      : "Export this clip to \(destination.label).")
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Save or share this recording.")
    }
}

/// Vertical "downloading…" panel used before the first frame is
/// ready and again as an overlay during an explicit Export staging.
/// Renders progress in bytes, throughput when known, and falls back
/// to an indeterminate spinner if the upstream omits Content-Length.
struct RecordingDownloadProgressPanel: View {
    let bytesReceived: Int64
    let totalBytes: Int64
    let startedAt: Date?
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        let received = bytesReceived
        let total = max(totalBytes, received)
        if total > 0 {
            ProgressView(value: min(1.0, Double(received) / Double(total)))
                .frame(maxWidth: 320)
            HStack(spacing: 6) {
                Text("\(byteString(received)) / \(byteString(total))")
                if let rate = throughput {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(byteString(rate))/s")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.regular)
            Text("Starting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var throughput: Int64? {
        guard let startedAt, bytesReceived > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else { return nil }
        return Int64(Double(bytesReceived) / elapsed)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

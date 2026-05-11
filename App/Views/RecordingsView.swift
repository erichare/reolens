import SwiftUI
import AVKit
import ReolinkAPI

/// Browses recordings stored on the Reolink Home Hub / NVR for a given channel.
/// Date picker → Search query → list of files → AVPlayer for playback.
struct RecordingsView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @State private var selectedDate: Date = Date()
    @State private var streamType: String = "main"
    @State private var files: [SearchFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nowPlaying: PlayableRecording?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task(id: TaskKey(date: selectedDate, stream: streamType)) {
            await reload()
        }
        .sheet(item: $nowPlaying) { recording in
            RecordingPlayerSheet(recording: recording)
        }
    }

    private struct TaskKey: Equatable {
        let date: Date
        let stream: String
    }

    private var controls: some View {
        HStack(spacing: 12) {
            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .labelsHidden()
            Picker("Stream", selection: $streamType) {
                Text("Main").tag("main")
                Text("Sub").tag("sub")
            }
            .labelsHidden()
            .frame(width: 110)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load recordings", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await reload() } }
            }
        } else if files.isEmpty && !isLoading {
            ContentUnavailableView(
                "No recordings",
                systemImage: "tray",
                description: Text("No recordings on this channel for \(selectedDate, format: .dateTime.day().month().year()).")
            )
        } else {
            List(files) { file in
                fileRow(file)
                    .contentShape(.rect)
                    .onTapGesture { play(file) }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: SearchFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeLabel(for: file)).font(.body.monospacedDigit())
                Text(metaLabel(for: file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            detectionTags(for: file)
            if let size = file.sizeMB {
                Text("\(size, specifier: "%.1f") MB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detectionTags(for file: SearchFile) -> some View {
        let detections = file.triggers
        if !detections.isEmpty {
            HStack(spacing: 6) {
                ForEach(detections, id: \.self) { d in
                    Label(d.label, systemImage: d.systemImage)
                        .labelStyle(.iconOnly)
                        .help(d.label)
                        .foregroundStyle(tint(for: d))
                        .font(.caption)
                }
            }
        }
    }

    private func tint(for detection: DetectionType) -> Color {
        switch detection {
        case .motion: .yellow
        case .person: .green
        case .vehicle: .blue
        case .pet: .orange
        case .face: .pink
        case .packageDelivery: .brown
        case .visitor: .indigo
        case .other: .secondary
        }
    }

    private func timeLabel(for file: SearchFile) -> String {
        guard let start = file.startDate else { return file.name }
        let label = dateFormatter.string(from: start)
        if let duration = file.durationSeconds {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return "\(label)  ·  \(mins)m \(secs)s"
        }
        return label
    }

    private func metaLabel(for file: SearchFile) -> String {
        var parts: [String] = []
        if let type = file.type { parts.append(type.capitalized) }
        if let w = file.width, let h = file.height { parts.append("\(w)×\(h)") }
        if let fps = file.frameRate { parts.append("\(fps) fps") }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let cal = Calendar.current
        let start = cal.startOfDay(for: selectedDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else { return }

        do {
            let env = try await session.client.send(
                Commands.search(
                    channel: channel.channel,
                    onlyStatus: false,
                    streamType: streamType,
                    start: start,
                    end: end
                ),
                as: SearchEnvelope.self
            )
            let result = env.SearchResult.File ?? []
            files = result.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        } catch {
            errorMessage = "\(error)"
            files = []
        }
    }

    private func play(_ file: SearchFile) {
        Task {
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let url = StreamURLs(credentials: creds).recordingDownload(
                source: file.name,
                output: file.name,
                token: token
            )
            nowPlaying = PlayableRecording(file: file, url: url)
        }
    }
}

struct PlayableRecording: Identifiable, Hashable {
    let file: SearchFile
    let url: URL
    var id: String { file.name }
}

struct RecordingPlayerSheet: View {
    let recording: PlayableRecording
    @Environment(\.dismiss) private var dismiss
    @State private var downloader = RecordingDownloader()
    @State private var startedAt: Date?

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
        .onDisappear {
            downloader.cancel()
            downloader.cleanupTempFile()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.file.name).font(.headline)
                if let start = recording.file.startDate {
                    Text(start, format: .dateTime.day().month().year().hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            if let localURL = downloader.localURL {
                AVPlayerHostView(url: localURL)
                    .frame(minWidth: 720, minHeight: 405)
            } else {
                downloadingPanel
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't play this recording", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.caption).textSelection(.enabled)
            } actions: {
                Button("Retry") { downloader.start(url: recording.url) }
            }
        }
    }

    private var downloadingPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Downloading recording…").font(.headline)
            // Foundation's Progress reports `totalUnitCount = -1` when the
            // server didn't send Content-Length. Fall back to the size from
            // Search results in that case.
            let received = downloader.bytesReceived
            let total = downloader.totalBytes > 0
                ? downloader.totalBytes
                : (recording.file.size.map(Int64.init) ?? 0)
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

/// macOS AVPlayer host that auto-plays the URL when shown.
struct AVPlayerHostView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url, current != url {
            let player = AVPlayer(url: url)
            nsView.player = player
            player.play()
        }
    }
}

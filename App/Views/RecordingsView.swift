import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import ReolinkBaichuan

private let log = Logger(subsystem: "com.reolens.app", category: "recordings")

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
    @State private var rawResponse: String?
    @State private var showRawResponse = false
    @State private var eventLog: [HubEvent] = []
    @State private var eventsUnsupported = false
    /// Baichuan-delivered alarm-tagged recording info, keyed by file name
    /// prefix. Populated by `findAlarmVideo` on the hub.
    @State private var alarmVideoByName: [String: BaichuanAlarmVideoFile] = [:]
    @State private var alarmVideoLoading = false

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
            if !files.isEmpty {
                let totalDetections = files.reduce(0) { $0 + effectiveDetections(for: $1).count }
                if totalDetections == 0
                    && eventsUnsupported
                    && files.allSatisfy({ $0.triggers.isEmpty })
                    && session.aiEventLog.isEmpty
                    && alarmVideoByName.isEmpty
                    && !alarmVideoLoading {
                    Divider()
                    aiUnavailableFooter
                } else if !alarmVideoByName.isEmpty || !session.aiEventLog.isEmpty {
                    Divider()
                    baichuanActiveFooter
                }
            }
        }
        .task(id: TaskKey(date: selectedDate, stream: streamType)) {
            await reload()
        }
        .sheet(item: $nowPlaying) { recording in
            RecordingPlayerSheet(recording: recording)
        }
    }

    private var aiUnavailableFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("AI tags aren't being delivered from this camera. CGI Search doesn't expose them, and the Baichuan event channel hasn't reported any events yet for this session — tags will appear here as new motion/AI events are pushed by the hub.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.tertiary)
    }

    private var baichuanActiveFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Text("AI tags from Reolink Baichuan: \(alarmVideoByName.count) tagged recording\(alarmVideoByName.count == 1 ? "" : "s"), \(session.aiEventLog.count) live event\(session.aiEventLog.count == 1 ? "" : "s") this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if alarmVideoLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.tertiary)
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
            if rawResponse != nil {
                Button {
                    showRawResponse = true
                } label: {
                    Label("Raw JSON", systemImage: "curlybraces")
                }
                .help("Show the raw JSON response from the camera. Useful for diagnosing why detection icons don't match.")
                .popover(isPresented: $showRawResponse) {
                    RawResponseView(text: rawResponse ?? "")
                }
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

    /// Detection tag pipeline:
    ///   1. First check `file.triggers` (the `Search`-response bitfield). On
    ///      firmware that doesn't populate it (e.g. Home Hub Pro continuous
    ///      recordings), this is empty.
    ///   2. Fall back to events from `GetEvents` matched to this file by time
    ///      overlap — captures AI events on hubs that surface them through
    ///      that command.
    ///   3. If both are empty, render nothing (we don't fake data).
    @ViewBuilder
    private func detectionTags(for file: SearchFile) -> some View {
        let detections = effectiveDetections(for: file)
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

    private func effectiveDetections(for file: SearchFile) -> [DetectionType] {
        if !file.triggers.isEmpty { return file.triggers }

        var matches: [DetectionType] = []
        var seen = Set<DetectionType>()

        // 1. Best source: Baichuan's findAlarmVideo response, matched by file
        //    name. Reolink uses a different file-name encoding here than for
        //    the CGI Search response, so we try both exact-match and the
        //    leading-prefix (everything before the first `-` group).
        if let av = alarmVideoMatch(for: file.name) {
            for d in av.detections where seen.insert(d).inserted {
                matches.append(d)
            }
            if !matches.isEmpty { return matches }
        }

        if let start = file.startDate, let end = file.endDate {
            // 2. Live Baichuan AlarmEventList pushes received this session.
            for event in session.aiEventLog
                where event.channelID == channel.channel
                && event.timestamp >= start
                && event.timestamp <= end {
                if let d = event.detectionType, seen.insert(d).inserted {
                    matches.append(d)
                }
            }
            // 3. Speculative GetEvents probe response (rare).
            for entry in eventLog where entry.overlaps(start: start, end: end) {
                for d in entry.detectionTypes where seen.insert(d).inserted {
                    matches.append(d)
                }
            }
        }
        return matches
    }

    private func alarmVideoMatch(for fileName: String) -> BaichuanAlarmVideoFile? {
        if let exact = alarmVideoByName[fileName] { return exact }
        // The CGI Search file name often has the form
        // `0-0-{timestamp}-00000-{deviceUID}` while Baichuan's findAlarmVideo
        // returns just the timestamp portion. Match on that core if possible.
        let core = fileName
            .split(separator: "-")
            .dropFirst(2)
            .first.map(String.init) ?? fileName
        return alarmVideoByName.values.first { $0.fileName.contains(core) || core.contains($0.fileName) }
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

        let command = Commands.search(
            channel: channel.channel,
            onlyStatus: false,
            streamType: streamType,
            start: start,
            end: end
        )
        do {
            // Capture raw bytes for diagnostics — useful when detection icons
            // don't show because firmware uses a field name we don't know yet.
            let raw = try await session.client.sendCapturingRaw(command)
            let pretty = prettyPrint(raw) ?? String(data: raw, encoding: .utf8) ?? "<binary>"
            rawResponse = pretty
            log.info("Search raw response (channel=\(self.channel.channel)):\n\(pretty, privacy: .public)")

            let envelopes = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: raw)
            guard let firstValue = envelopes.first?.value else {
                files = []
                errorMessage = "Empty response from camera"
                return
            }
            let result = firstValue.SearchResult.File ?? []
            files = result.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        } catch {
            errorMessage = "\(error)"
            files = []
        }

        // Once per day-load, probe for AI events through `GetEvents`. Reolink
        // Home Hub Pro's `Search` response doesn't include trigger metadata,
        // but some firmware exposes it via this separate endpoint. Capture
        // whatever shape comes back — `HubEvent` decodes permissively.
        if !eventsUnsupported {
            await loadEvents(start: start, end: end)
        }

        // The real source of historical AI tags: Baichuan's findAlarmVideo
        // command (msg 272/273/274). Runs in parallel — recordings appear
        // immediately and detection icons populate as soon as this returns.
        await loadAlarmVideos(start: start, end: end)
    }

    private func loadAlarmVideos(start: Date, end: Date) async {
        guard let client = session.baichuanClient else {
            log.info("Baichuan client not yet ready; skipping findAlarmVideo")
            return
        }
        alarmVideoLoading = true
        defer { alarmVideoLoading = false }
        do {
            let files = try await client.findAlarmVideos(
                channel: UInt8(channel.channel),
                start: start,
                end: end,
                streamType: streamType
            )
            var byName: [String: BaichuanAlarmVideoFile] = [:]
            for f in files {
                byName[f.fileName] = f
            }
            alarmVideoByName = byName
            log.info("findAlarmVideo channel=\(self.channel.channel) entries=\(files.count) tags=\(files.flatMap { $0.detections }.map { $0.label }.joined(separator: ","), privacy: .public)")
        } catch {
            log.error("findAlarmVideo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadEvents(start: Date, end: Date) async {
        let cmd = Commands.getEvents(channel: channel.channel, start: start, end: end)
        do {
            let raw = try await session.client.sendCapturingRaw(cmd)
            log.info("GetEvents raw response (channel=\(self.channel.channel)):\n\(String(data: raw, encoding: .utf8) ?? "<binary>", privacy: .public)")
            let envelopes = (try? JSONDecoder().decode([CGIResponse<HubEventEnvelope>].self, from: raw)) ?? []
            if let firstError = envelopes.first?.error,
               firstError.rspCode == CGIErrorCode.notSupport.rawValue {
                log.info("GetEvents not supported on this firmware; falling back to no AI metadata.")
                eventsUnsupported = true
                eventLog = []
                return
            }
            // Home Hub Pro returns current alarm state under `value.ai`,
            // `value.md`, `value.visitor` — NOT a historical event list.
            // Our `HubEventEnvelope` decoder only finds events when one of its
            // candidate top-level keys is present (EventList, Events, …).
            // If no events came back, mark unsupported so the UI footer shows.
            let decoded = envelopes.first?.value?.events ?? []
            eventLog = decoded
            if decoded.isEmpty {
                log.info("GetEvents returned current-state only (not a historical event log). Marking unsupported.")
                eventsUnsupported = true
            }
        } catch {
            log.debug("GetEvents probe failed: \(error.localizedDescription, privacy: .public)")
            eventsUnsupported = true
        }
    }

    private func prettyPrint(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) else { return nil }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: pretty, encoding: .utf8)
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
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
            .background(.background.tertiary)
            .clipShape(.rect(cornerRadius: 6))
        }
        .padding(12)
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

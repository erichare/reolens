import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import ReolinkBaichuan
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "ios-recordings")

/// iOS recordings browser. Mirrors the macOS app's approach:
///
/// - Loads BOTH the main and sub stream's CGI Search results, matches
///   them by time-range overlap so each row knows its high- and
///   low-quality download options.
/// - Tap a row → play the sub stream (smaller, faster download) when
///   available; long-press for explicit quality choice.
/// - Detection-trigger badges come from two sources, in priority order:
///     1. `SearchFile.triggers` — the CGI Search response bitfield.
///     2. `CameraSession.aiEventLog` — live Baichuan AI alerts
///        collected since the session connected, matched by time
///        overlap.
struct RecordingsView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @State private var selectedDate: Date = Date()
    @State private var files: [SearchFile] = []
    @State private var subFiles: [SearchFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nowPlaying: PlayableRecording?

    var body: some View {
        VStack(spacing: 0) {
            DatePicker(
                "Day",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()
            content
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedDate) {
            await load()
        }
        .sheet(item: $nowPlaying) { recording in
            RecordingPlayerSheet(recording: recording)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading recordings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't load recordings",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if files.isEmpty {
            ContentUnavailableView(
                "No recordings",
                systemImage: "moon.zzz",
                description: Text("Nothing recorded on \(selectedDate.formatted(date: .abbreviated, time: .omitted)).")
            )
        } else {
            List(files) { file in
                row(for: file)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(for file: SearchFile) -> some View {
        let sub = subFileMatch(for: file)
        let detections = effectiveDetections(for: file)
        Button {
            // Tap default: play the sub stream when available — much
            // smaller and faster to download than the main stream.
            // Falls back to main if no matching sub exists (some
            // single-stream cameras / certain firmware).
            Task { playEntry(file: file, sub: sub, preferSub: true) }
        } label: {
            RecordingRow(file: file, subFile: sub, detections: detections)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { playEntry(file: file, sub: sub, preferSub: true) }
            } label: {
                Label("Play (Low Quality)", systemImage: "play.circle")
            }
            .disabled(sub == nil)
            Button {
                Task { playEntry(file: file, sub: sub, preferSub: false) }
            } label: {
                Label("Play (High Quality)", systemImage: "play.circle.fill")
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        files = []
        subFiles = []

        if session.channels.isEmpty {
            await session.connect()
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        // Match the macOS app's end: 23:59:59 of the SAME day (one
        // second before midnight of day+1) rather than 00:00:00 of
        // the next day. Reolink's Search treats both as inclusive,
        // and using the end-of-same-day form avoids any ambiguity.
        guard let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else { return }

        // Run main → sub SERIALLY. Reolink Home Hub Pro returns
        // `rcv failed` (rspCode=-17) when two Search commands hit it
        // concurrently on the same channel, which makes both calls
        // return an empty file list — user sees "No recordings" even
        // when there are plenty. The macOS app learned this the hard
        // way too; same serialization comment lives in
        // App/Views/RecordingsView.swift.
        let mainResult = await fetchSearch(streamType: "main", start: start, end: end)
        switch mainResult {
        case .success(let mainList):
            var seen = Set<String>()
            let unique = mainList.filter { seen.insert($0.name).inserted }
            files = unique.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        case .failure(let message):
            errorMessage = message
            return
        }

        // Sub-stream failure is non-fatal — battery cameras and some
        // firmware don't produce a sub-stream recording. We just skip
        // the SD size pill and quality picker for those rows.
        let subResult = await fetchSearch(streamType: "sub", start: start, end: end)
        if case .success(let subList) = subResult {
            var seen = Set<String>()
            subFiles = subList.filter { seen.insert($0.name).inserted }
        } else if case .failure(let message) = subResult {
            log.info("Sub-stream Search unavailable on channel \(channel.channel): \(message, privacy: .public)")
        }
    }

    private enum SearchOutcome {
        case success([SearchFile])
        case failure(String)
    }

    private func fetchSearch(streamType: String, start: Date, end: Date) async -> SearchOutcome {
        let command = Commands.search(
            channel: channel.channel,
            onlyStatus: false,
            streamType: streamType,
            start: start,
            end: end
        )
        do {
            let raw = try await session.client.sendCapturingRaw(command)
            let envelopes = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: raw)
            return .success(envelopes.first?.value?.SearchResult.File ?? [])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Find the sub-stream file that best matches `file`'s main-stream
    /// time range. The two stream chunkers can emit slightly offset
    /// segment boundaries, so "longest temporal overlap wins" is more
    /// reliable than equality matching.
    private func subFileMatch(for file: SearchFile) -> SearchFile? {
        guard let mainStart = file.startDate, let mainEnd = file.endDate else { return nil }
        var best: (sub: SearchFile, overlap: TimeInterval)? = nil
        for sub in subFiles {
            guard let subStart = sub.startDate, let subEnd = sub.endDate else { continue }
            let lo = max(mainStart, subStart)
            let hi = min(mainEnd, subEnd)
            let overlap = hi.timeIntervalSince(lo)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (sub, overlap)
            }
        }
        return best?.sub
    }

    /// Detection-trigger pipeline mirroring the macOS app:
    ///   1. CGI `Search` response's `Trigger` bitfield, when populated.
    ///   2. Live Baichuan `aiEventLog` events received this session,
    ///      matched to the file's time range by channel + timestamp.
    private func effectiveDetections(for file: SearchFile) -> [DetectionType] {
        if !file.triggers.isEmpty { return file.triggers }
        guard let start = file.startDate, let end = file.endDate else { return [] }
        var matches: [DetectionType] = []
        var seen = Set<DetectionType>()
        for event in session.aiEventLog
            where event.channelID == channel.channel
                && event.timestamp >= start
                && event.timestamp <= end {
            if let d = event.detectionType, seen.insert(d).inserted {
                matches.append(d)
            }
        }
        return matches
    }

    private func playEntry(file: SearchFile, sub: SearchFile?, preferSub: Bool) {
        let target = (preferSub ? sub : file) ?? file
        Task {
            let credentials = await session.client.credentials
            let urls = StreamURLs(credentials: credentials)
            let token = await session.client.currentToken?.name
            let url = urls.recordingDownload(source: target.name, token: token)
            await MainActor.run {
                nowPlaying = PlayableRecording(
                    id: target.name,
                    url: url,
                    displayName: target.name,
                    detections: effectiveDetections(for: file),
                    startDate: target.startDate
                )
            }
        }
    }
}

private struct RecordingRow: View {
    let file: SearchFile
    let subFile: SearchFile?
    let detections: [DetectionType]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(timeLabel)
                        .font(.body.monospacedDigit())
                    if let duration = durationLabel {
                        Text(duration)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !detections.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(detections, id: \.self) { detection in
                            Label(detection.label, systemImage: detection.systemImage)
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(detection.tint.opacity(0.18), in: .capsule)
                                .foregroundStyle(detection.tint)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            sizeColumn
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let mainMB = sizeMB(for: file) {
                sizeBadge(label: "HD", value: mainMB, tint: .blue)
            }
            if let sub = subFile, let subMB = sizeMB(for: sub) {
                sizeBadge(label: "SD", value: subMB, tint: .secondary)
            }
        }
    }

    private func sizeBadge(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(tint.opacity(0.18), in: .capsule)
                .foregroundStyle(tint)
            Text("\(value, specifier: "%.1f") MB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sizeMB(for file: SearchFile) -> Double? {
        guard let size = file.size, size > 0 else { return nil }
        return Double(size) / 1_048_576.0
    }

    private var timeLabel: String {
        guard let start = file.startDate else { return file.name }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var durationLabel: String? {
        guard let seconds = file.durationSeconds, seconds > 0 else { return nil }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private extension DetectionType {
    var label: String {
        switch self {
        case .motion: "Motion"
        case .person: "Person"
        case .vehicle: "Vehicle"
        case .pet: "Pet"
        case .face: "Face"
        case .packageDelivery: "Package"
        case .visitor: "Visitor"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .motion: "figure.walk.motion"
        case .person: "figure.stand"
        case .vehicle: "car.fill"
        case .pet: "pawprint.fill"
        case .face: "face.smiling"
        case .packageDelivery: "shippingbox.fill"
        case .visitor: "person.crop.circle"
        case .other: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .motion: .yellow
        case .person: .green
        case .vehicle: .blue
        case .pet: .orange
        case .face: .pink
        case .packageDelivery: .brown
        case .visitor: .purple
        case .other: .gray
        }
    }
}

struct PlayableRecording: Identifiable, Hashable {
    let id: String
    let url: URL
    let displayName: String
    let detections: [DetectionType]
    let startDate: Date?
}

/// Download-then-play sheet for Reolink recordings — see the long
/// header comment a few revisions ago. Briefly: AVPlayer can't
/// negotiate Reolink's CGI Download endpoint reliably, so we
/// download the file via RecordingDownloader (parallel HTTP Range,
/// auth-correct) and play the local file with AVPlayer.
struct RecordingPlayerSheet: View {
    let recording: PlayableRecording

    @Environment(\.dismiss) private var dismiss
    @State private var downloader = RecordingDownloader()
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(headerTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    downloader.start(url: recording.url)
                }
                .onChange(of: downloader.state) { _, newState in
                    if newState == .ready, let localURL = downloader.localURL {
                        let item = AVPlayerItem(url: localURL)
                        let p = AVPlayer(playerItem: item)
                        self.player = p
                        p.play()
                    }
                }
                .onDisappear {
                    player?.pause()
                    player?.replaceCurrentItem(with: nil)
                    player = nil
                    downloader.cancel()
                    // Note: NO cleanupTempFile() here. The downloader
                    // promotes completed files to the cache directory
                    // (see RecordingDownloader.promoteToCache), so a
                    // re-tap on the same recording later is a cache
                    // hit. cleanupTempFile() is now also cache-aware
                    // and won't delete cached files, but skipping the
                    // call entirely keeps the intent obvious.
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloader.state {
        case .idle:
            ProgressView("Preparing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .downloading:
            downloadProgress
        case .ready:
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView("Starting playback…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't download this recording", systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 8) {
                    Text("The camera or hub refused the download request.")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } actions: {
                Button("Try Again") {
                    downloader.start(url: recording.url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(spacing: 8) {
                Text("Downloading recording")
                    .font(.headline)
                Text(byteCountLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if downloader.totalBytes > 0 {
                ProgressView(value: Double(downloader.bytesReceived), total: Double(downloader.totalBytes))
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var byteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: downloader.bytesReceived)
        guard downloader.totalBytes > 0 else { return received }
        let total = formatter.string(fromByteCount: downloader.totalBytes)
        return "\(received) of \(total)"
    }

    private var headerTitle: String {
        recording.startDate?.formatted(date: .abbreviated, time: .shortened)
            ?? recording.displayName
    }
}

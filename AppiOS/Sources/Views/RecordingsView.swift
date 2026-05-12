import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import ReolinkBaichuan
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "ios-recordings")

/// iOS recordings browser. Loads alarm-tagged recordings for a chosen
/// day via Baichuan's `findAlarmVideo`, lists them with detection
/// badges, and plays them in an AVPlayer sheet on tap.
///
/// The Mac app's RecordingsView is richer (CGI Search + sub-stream
/// preview + raw JSON popover + download-to-disk + AI event matching
/// across endpoints). For v0.2 iOS we ship the alarm-video path only —
/// it's what users actually want most days, and the other surfaces are
/// straightforward to add in a point release.
struct RecordingsView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @State private var selectedDate: Date = Date()
    @State private var entries: [BaichuanAlarmVideoFile] = []
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
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No recordings",
                systemImage: "moon.zzz",
                description: Text("No alarm-tagged recordings on \(selectedDate.formatted(date: .abbreviated, time: .omitted)).")
            )
        } else {
            List(entries) { entry in
                Button {
                    Task { await playEntry(entry) }
                } label: {
                    RecordingRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        entries = []

        // Ensure the session is connected and we have a Baichuan client
        // and a per-channel UID. The .task wrapper on CameraDetailView
        // kicks off connect(), but we may have navigated straight here
        // from the iPad sidebar before that finished.
        if session.channels.isEmpty {
            await session.connect()
        }
        guard let client = session.baichuanClient else {
            errorMessage = "Baichuan client not connected yet."
            return
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        // Per-channel UID is required when the device is a hub fronting
        // multiple cameras. Falls back to a Baichuan probe if Search
        // didn't populate one.
        let uid: String
        if let cgiUID = channel.uid, !cgiUID.isEmpty {
            uid = cgiUID
        } else {
            uid = await client.fetchUID(channelID: UInt8(channel.channel))
        }

        do {
            let files = try await client.findAlarmVideos(
                channel: UInt8(channel.channel),
                start: start,
                end: end,
                streamType: "main",
                uid: uid
            )
            // The Reolink hub occasionally returns the same fileName
            // twice (e.g. when an alarm-marked recording and a
            // motion-marked recording cover the exact same timestamp).
            // Dedupe by fileName so SwiftUI ForEach doesn't warn about
            // duplicate IDs, which makes per-row swipe / context menus
            // misroute.
            var seen = Set<String>()
            let unique = files.filter { seen.insert($0.fileName).inserted }
            entries = unique.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        } catch {
            log.error("findAlarmVideos failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func playEntry(_ entry: BaichuanAlarmVideoFile) async {
        let credentials = await session.client.credentials
        let urls = StreamURLs(credentials: credentials)
        // Use the cached token if we have one; the helper falls back to
        // embedded user/password query params otherwise.
        let token = await session.client.currentToken?.name
        let url = urls.recordingDownload(source: entry.fileName, token: token)
        nowPlaying = PlayableRecording(
            id: entry.id,
            url: url,
            displayName: entry.fileName,
            detections: entry.detections,
            startDate: entry.startDate
        )
    }
}

private struct RecordingRow: View {
    let entry: BaichuanAlarmVideoFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.tint)
                Text(timeLabel)
                    .font(.body.monospacedDigit())
                Spacer()
                Text(durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !entry.detections.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.detections, id: \.self) { detection in
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
        .padding(.vertical, 4)
    }

    private var timeLabel: String {
        guard let start = entry.startDate else { return entry.fileName }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var durationLabel: String {
        guard let start = entry.startDate, let end = entry.endDate else { return "" }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds > 0 else { return "" }
        let m = seconds / 60
        let s = seconds % 60
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

/// Download-then-play sheet for Reolink alarm clips.
///
/// Why download instead of streaming directly with `AVPlayer(url:)`:
/// Reolink's CGI download endpoint accepts auth via `?user=&password=`
/// query parameters, but AVPlayer often fails to negotiate the
/// resulting response — chunked transfer encoding, missing
/// Content-Length, or self-signed TLS that AVPlayer rejects even
/// though ATS is set to allow local networking. The user saw a blank
/// VideoPlayer that never started.
///
/// Solution: reuse the macOS `RecordingDownloader` (lives in
/// AppShared, already battle-tested), which makes parallel HTTP Range
/// requests with a plain URLSession that handles the auth and
/// response shape correctly. When the download lands on disk, hand
/// the local file URL to AVPlayer — local files always Just Work.
///
/// The trade-off is the user waits for the download before playback
/// starts. We show a progress UI with bytes-downloaded so the wait
/// isn't a silent spinner. A future iteration could use
/// `AVAssetResourceLoaderDelegate` for progressive playback while
/// downloading, but the download-then-play path is reliable enough
/// for 0.3.0 and matches how the macOS Save / Open works.
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
                    // Kick off the download once on first appear. Re-entering
                    // .task on subsequent state changes is harmless because
                    // RecordingDownloader.start() guards against re-entry.
                    downloader.start(url: recording.url)
                }
                .onChange(of: downloader.state) { _, newState in
                    if newState == .ready, let localURL = downloader.localURL {
                        // Switch from progress UI to playback. AVPlayer
                        // against a local file URL has none of the auth /
                        // encoding issues that broke streaming directly
                        // from the Reolink CGI endpoint.
                        let item = AVPlayerItem(url: localURL)
                        let p = AVPlayer(playerItem: item)
                        self.player = p
                        p.play()
                    }
                }
                .onDisappear {
                    // Release the AVPlayerItem before deleting the temp
                    // file so the file isn't held open at delete time.
                    player?.pause()
                    player?.replaceCurrentItem(with: nil)
                    player = nil
                    downloader.cancel()
                    downloader.cleanupTempFile()
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

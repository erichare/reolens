import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import ReolinkBaichuan
import ReolinkStreaming
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
    /// "Scroll-to-and-play" hint passed by the notification-tap
    /// pipeline (see `AppIntentFocus.Target.recording`). Non-nil →
    /// jump to the day, find the closest file, auto-play.
    var scrollTarget: Date? = nil

    /// 0.6.0 — All network state (files, subFiles, alarmVideoEntries,
    /// monthStatuses, isLoading, errorMessage) lives on the loader.
    /// The view owns the date binding, the AI-filter pill state, and
    /// presentation-only state (sheet, scroll targets).
    @State private var loader: RecordingsLoader
    @State private var pendingScrollTarget: Date?
    @State private var playedScrollTarget: Bool = false
    @State private var nowPlaying: PlayableRecording?
    @State private var aiFilter: Set<DetectionType> = []

    init(session: CameraSession, channel: ChannelStatus, scrollTarget: Date? = nil) {
        self.session = session
        self.channel = channel
        self.scrollTarget = scrollTarget
        let initial = RecordingsLoader(
            source: session,
            channel: channel.channel,
            channelUID: channel.uid,
            captureRawResponses: false,
            initialDate: Date()
        )
        self._loader = State(wrappedValue: initial)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { self.loader.selectedDate },
            set: { self.loader.selectedDate = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DatePicker(
                "Day",
                selection: dateBinding,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .padding(.horizontal)
            .padding(.vertical, 8)
            // 0.5.0 Liquid Glass — date picker reads as a header
            // toolbar over the day / timeline / filter stack.
            .reolensGlassToolbar()

            MonthRecordingDensity(selectedDate: dateBinding, monthStatuses: loader.monthStatuses)
                .reolensGlassToolbar()

            if !filteredFiles.isEmpty {
                DayTimelineStrip(
                    day: loader.selectedDate,
                    files: filteredFiles,
                    events: dayEvents,
                    onTapSegment: { file in
                        let sub = loader.subFileMatch(for: file)
                        playEntry(file: file, sub: sub, preferSub: true)
                    }
                )
                .reolensGlassToolbar()
            }

            AIEventFilterBar(selected: $aiFilter)
                .reolensGlassToolbar()

            Divider()
            content
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loader.selectedDate) {
            await loader.reload()
            if let target = pendingScrollTarget, !playedScrollTarget {
                playedScrollTarget = true
                pendingScrollTarget = nil
                autoPlayClipNearest(target)
            }
        }
        .onAppear {
            if let target = scrollTarget, !playedScrollTarget {
                pendingScrollTarget = target
                let day = Calendar.current.startOfDay(for: target)
                if Calendar.current.startOfDay(for: loader.selectedDate) != day {
                    loader.selectedDate = target
                } else {
                    Task {
                        playedScrollTarget = true
                        pendingScrollTarget = nil
                        autoPlayClipNearest(target)
                    }
                }
            }
        }
        .sheet(item: $nowPlaying) { recording in
            RecordingPlayerSheet(recording: recording)
        }
    }

    /// Locate the file whose time range contains `target` (preferred)
    /// or the file with the closest start time. Plays via the same
    /// `playEntry` path a manual tap uses.
    private func autoPlayClipNearest(_ target: Date) {
        if let containing = filteredFiles.first(where: { file in
            guard let start = file.startDate, let end = file.endDate else { return false }
            return start <= target && target <= end
        }) {
            let sub = loader.subFileMatch(for: containing)
            playEntry(file: containing, sub: sub, preferSub: true)
            return
        }
        let withDistance = filteredFiles.compactMap { file -> (SearchFile, TimeInterval)? in
            guard let start = file.startDate else { return nil }
            return (file, abs(start.timeIntervalSince(target)))
        }
        if let (closest, _) = withDistance.min(by: { $0.1 < $1.1 }) {
            let sub = loader.subFileMatch(for: closest)
            playEntry(file: closest, sub: sub, preferSub: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loader.isLoading {
            ProgressView("Loading recordings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = loader.errorMessage {
            ContentUnavailableView(
                "Couldn't load recordings",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if loader.files.isEmpty {
            ContentUnavailableView(
                "No recordings",
                systemImage: "moon.zzz",
                description: Text("Nothing recorded on \(loader.selectedDate.formatted(date: .abbreviated, time: .omitted)).")
            )
        } else if filteredFiles.isEmpty {
            ContentUnavailableView(
                "No matching recordings",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No recordings match the selected AI filter. Tap chips above to remove filters.")
            )
        } else {
            List(filteredFiles) { file in
                row(for: file)
            }
            .listStyle(.plain)
        }
    }

    private var filteredFiles: [SearchFile] {
        guard !aiFilter.isEmpty else { return loader.files }
        return loader.files.filter { file in
            let detections = Set(loader.effectiveDetections(for: file))
            return !detections.isDisjoint(with: aiFilter)
        }
    }

    private var dayEvents: [TimestampedAIEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: loader.selectedDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return session.aiEventLog.filter { ev in
            ev.channelID == channel.channel
            && ev.timestamp >= startOfDay
            && ev.timestamp < endOfDay
        }
    }

    @ViewBuilder
    private func row(for file: SearchFile) -> some View {
        let sub = loader.subFileMatch(for: file)
        let detections = loader.effectiveDetections(for: file)
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
            Divider()
            Button {
                Task { await bookmarkAndDownload(file: file) }
            } label: {
                Label("Bookmark this clip", systemImage: "bookmark")
            }
        }
        // 0.5.1 — trailing swipe surfaces Bookmark so users can
        // archive a recording without first playing it. Pairs with
        // the auto background-download in `bookmarkAndDownload`.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await bookmarkAndDownload(file: file) }
            } label: {
                Label("Bookmark", systemImage: "bookmark.fill")
            }
            .tint(.accentColor)
        }
    }

    /// 0.5.1 — Bookmark + auto background-download in one action.
    /// Bookmark metadata persists via `RecordingBookmarkStore`
    /// (iCloud-synced JSON); the clip itself downloads through the
    /// `BookmarkAutoDownloader` background URLSession so the user can
    /// background the app and still get the file.
    private func bookmarkAndDownload(file: SearchFile) async {
        let bookmark = RecordingBookmark(
            cameraID: session.entry.id,
            channel: channel.channel,
            startEpoch: file.startDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            endEpoch: file.endDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            note: nil,
            aiTagsAtMark: file.triggers.map(\.rawValue)
        )
        do {
            try RecordingBookmarkStore.add(bookmark)
        } catch {
            // Surfacing a sheet on every bookmark feels heavy; the
            // alert path can come later if users hit this in the wild.
            return
        }
        let token = await session.client.currentToken?.name
        let creds = await session.client.credentials
        let url = StreamURLs(credentials: creds).recordingDownload(
            source: file.name,
            output: file.name,
            token: token
        )
        await BookmarkAutoDownloader.shared.enqueue(bookmark: bookmark, sourceURL: url)
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
                    detections: loader.effectiveDetections(for: file),
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
                .onDisappear {
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
            if let localURL = downloader.localURL {
                // Use AVPlayerViewController directly (not SwiftUI's
                // VideoPlayer wrapper). VideoPlayer + @State<AVPlayer>
                // had a race where the player binding flickered between
                // body re-renders — symptom: image flashed for a frame,
                // then "Starting playback…" returned. AVPlayerViewController
                // owns its own player and binds on appear; no SwiftUI
                // intermediate state to lose.
                AVPlayerHostView(url: localURL)
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

/// AVPlayerViewController wrapped for SwiftUI. Mirrors the macOS app's
/// `AVPlayerHostView` (NSViewRepresentable wrapping AVPlayerView). Owns
/// its own AVPlayer rather than receiving one from SwiftUI @State,
/// which avoids a binding race where the player reference could go
/// nil between body re-renders, briefly showing the camera frame then
/// reverting to "Starting playback…".
private struct AVPlayerHostView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = true
        // Auto-play once the system has the controller in its view
        // hierarchy. Calling play() before that point silently no-ops
        // on some firmware.
        DispatchQueue.main.async {
            controller.player?.play()
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // If the URL changed (different recording on the same sheet),
        // swap the player. Same-URL re-binds are no-ops.
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        controller.player = AVPlayer(url: url)
        controller.player?.play()
    }
}

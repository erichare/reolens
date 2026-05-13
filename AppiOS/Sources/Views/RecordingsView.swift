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
    /// "Scroll-to-and-play" hint passed by the notification-tap
    /// pipeline (see `AppIntentFocus.Target.recording`). Non-nil →
    /// jump to the day, find the closest file, auto-play.
    var scrollTarget: Date? = nil

    @State private var selectedDate: Date = Date()
    @State private var pendingScrollTarget: Date?
    @State private var playedScrollTarget: Bool = false
    @State private var files: [SearchFile] = []
    @State private var subFiles: [SearchFile] = []
    /// Baichuan `findAlarmVideo` results for the same day. Cross-
    /// referenced by time-range overlap to populate AI detection
    /// badges on rows whose CGI `Search` trigger bitfield is empty
    /// (the common case on Home Hub Pro firmware). Mirrors the
    /// macOS app's pipeline.
    @State private var alarmVideoEntries: [BaichuanAlarmVideoFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nowPlaying: PlayableRecording?
    @State private var aiFilter: Set<DetectionType> = []
    @State private var monthStatuses: [SearchStatus] = []

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
            // 0.5.0 Liquid Glass — date picker reads as a header
            // toolbar over the day / timeline / filter stack.
            .reolensGlassToolbar()

            MonthRecordingDensity(selectedDate: $selectedDate, monthStatuses: monthStatuses)
                .reolensGlassToolbar()

            if !filteredFiles.isEmpty {
                DayTimelineStrip(
                    day: selectedDate,
                    files: filteredFiles,
                    events: dayEvents,
                    onTapSegment: { file in
                        let sub = subFileMatch(for: file)
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
        .task(id: selectedDate) {
            await load()
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
                if Calendar.current.startOfDay(for: selectedDate) != day {
                    selectedDate = target
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
            let sub = subFileMatch(for: containing)
            playEntry(file: containing, sub: sub, preferSub: true)
            return
        }
        let withDistance = filteredFiles.compactMap { file -> (SearchFile, TimeInterval)? in
            guard let start = file.startDate else { return nil }
            return (file, abs(start.timeIntervalSince(target)))
        }
        if let (closest, _) = withDistance.min(by: { $0.1 < $1.1 }) {
            let sub = subFileMatch(for: closest)
            playEntry(file: closest, sub: sub, preferSub: true)
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
        guard !aiFilter.isEmpty else { return files }
        return files.filter { file in
            let detections = Set(effectiveDetections(for: file))
            return !detections.isDisjoint(with: aiFilter)
        }
    }

    private var dayEvents: [TimestampedAIEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: selectedDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return session.aiEventLog.filter { ev in
            ev.channelID == channel.channel
            && ev.timestamp >= startOfDay
            && ev.timestamp < endOfDay
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
        errorMessage = nil
        files = []
        subFiles = []
        alarmVideoEntries = []

        if session.channels.isEmpty {
            await session.connect()
        }
        guard session.status == .connected else {
            isLoading = false
            errorMessage = connectionUnavailableMessage()
            return
        }

        guard let (start, end) = searchWindow(for: selectedDate) else {
            isLoading = false
            files = []
            return
        }

        // Run main → sub SERIALLY. Reolink Home Hub Pro returns
        // `rcv failed` (rspCode=-17) when two Search commands hit it
        // concurrently on the same channel, which makes both calls
        // return an empty file list — user sees "No recordings" even
        // when there are plenty. The macOS app learned this the hard
        // way too; same serialization comment lives in
        // App/Views/RecordingsView.swift.
        let mainResult = await session.withBackgroundPollingPaused {
            await fetchSearch(streamType: "main", start: start, end: end)
        }
        switch mainResult {
        case .success(let mainList, let statuses):
            var seen = Set<String>()
            let unique = mainList.filter { seen.insert($0.name).inserted }
            files = unique.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
            if !statuses.isEmpty {
                monthStatuses = statuses
            }
        case .failure(let message):
            errorMessage = message
            isLoading = false
            return
        }

        // The user-visible list only needs the main-stream Search.
        // Show it immediately, then enrich rows with the sub-stream
        // match and Baichuan AI tags in the background. This mirrors
        // the macOS flow and keeps a slow tag lookup from feeling like
        // "recordings are still loading."
        isLoading = false

        Task { @MainActor in
            // Sub-stream failure is non-fatal — battery cameras and some
            // firmware don't produce a sub-stream recording. We just skip
            // the SD size pill and quality picker for those rows.
            let subResult = await session.withBackgroundPollingPaused {
                await fetchSearch(streamType: "sub", start: start, end: end)
            }
            if case .success(let subList, _) = subResult {
                var seen = Set<String>()
                subFiles = subList.filter { seen.insert($0.name).inserted }
            } else if case .failure(let message) = subResult {
                log.info("Sub-stream Search unavailable on channel \(channel.channel): \(message, privacy: .public)")
            }
        }

        // Cross-reference Baichuan's alarm-video list to pick up AI
        // detection tags that CGI Search's trigger bitfield doesn't
        // populate on Home Hub Pro firmware. Failure is non-fatal —
        // rows just fall back to whatever the Search bitfield carries
        // (often empty for hub-paired cameras, but never wrong).
        Task { @MainActor in
            if let baichuan = session.baichuanClient {
                let uid: String
                if let cgiUID = channel.uid, !cgiUID.isEmpty {
                    uid = cgiUID
                } else {
                    uid = await baichuan.fetchUID(channelID: UInt8(channel.channel))
                }
                do {
                    let entries = try await baichuan.findAlarmVideos(
                        channel: UInt8(channel.channel),
                        start: start,
                        end: end,
                        streamType: "main",
                        uid: uid
                    )
                    alarmVideoEntries = entries
                } catch {
                    log.info("findAlarmVideos for channel \(channel.channel) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func searchWindow(for day: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        // Match the macOS app's end: 23:59:59 of the SAME day (one
        // second before midnight of day+1) rather than 00:00:00 of
        // the next day. Reolink's Search treats both as inclusive,
        // and using the end-of-same-day form avoids ambiguity.
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else {
            return nil
        }
        let now = Date()
        guard start <= now else { return nil }
        return (start, min(endOfDay, now))
    }

    private func connectionUnavailableMessage() -> String {
        if case .failed(let reason) = session.connectionStage {
            return reason
        }
        if case .error(let message) = session.status {
            return message
        }
        return "Camera isn't connected yet."
    }

    private enum SearchOutcome {
        case success([SearchFile], statuses: [SearchStatus])
        case failure(String)
    }

    private func fetchSearch(streamType: String, start: Date, end: Date) async -> SearchOutcome {
        let startedAt = Date()
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
            let result = envelopes.first?.value?.SearchResult
            let files = result?.File ?? []
            let statuses = result?.Status ?? []
            log.info("Search completed channel=\(channel.channel) stream=\(streamType, privacy: .public) files=\(files.count) statuses=\(statuses.count) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s")
            return .success(files, statuses: statuses)
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
    ///   2. Baichuan `findAlarmVideo` entries whose time range
    ///      overlaps this CGI file's range. Most reliable source on
    ///      Home Hub Pro firmware.
    ///   3. Live Baichuan `aiEventLog` events received this session,
    ///      matched to the file's time range by channel + timestamp.
    private func effectiveDetections(for file: SearchFile) -> [DetectionType] {
        if !file.triggers.isEmpty { return file.triggers }

        var matches: [DetectionType] = []
        var seen = Set<DetectionType>()

        for av in alarmVideosOverlapping(file: file) {
            for d in av.detections where seen.insert(d).inserted {
                matches.append(d)
            }
        }
        if !matches.isEmpty { return matches }

        guard let start = file.startDate, let end = file.endDate else { return [] }
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

    /// Find every Baichuan alarm-video entry whose time range overlaps
    /// the given CGI Search file's. Half-open semantics — an entry
    /// that ends exactly at the file's start belongs to the previous
    /// file, not this one. Mirrors the macOS app's helper of the
    /// same name.
    private func alarmVideosOverlapping(file: SearchFile) -> [BaichuanAlarmVideoFile] {
        guard let fileStart = file.startDate, let fileEnd = file.endDate else {
            // Fall back to exact-filename match when timestamps are
            // missing (shouldn't happen on healthy firmware).
            return alarmVideoEntries.filter { $0.fileName == file.name }
        }
        return alarmVideoEntries.filter { av in
            if av.fileName == file.name { return true }
            guard let avStart = av.startDate, let avEnd = av.endDate else { return false }
            return avStart < fileEnd && avEnd > fileStart
        }
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

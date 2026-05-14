import SwiftUI
import AVKit
import OSLog
import ReolinkAPI
import ReolinkBaichuan
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "recordings")

/// Browses recordings stored on the Reolink Home Hub / NVR for a given channel.
/// Date picker → Search query → list of files → AVPlayer for playback.
struct RecordingsView: View {
    let session: CameraSession
    let channel: ChannelStatus
    /// Optional "scroll-to-and-play" hint set by the notification-tap
    /// routing pipeline (`AppIntentFocus.Target.recording` carries
    /// the event timestamp). When non-nil on appear, the view auto-
    /// selects the day containing the time, finds the closest file,
    /// scrolls it into view, and auto-plays. Reset to nil internally
    /// so re-renders don't loop.
    var scrollTarget: Date? = nil

    @Environment(CameraStore.self) private var store
    /// 0.6.0 — All network state (files, subFiles, alarmVideoEntries,
    /// monthStatuses, eventLog, eventsUnsupported, alarmVideoLoading,
    /// rawResponse, isLoading, errorMessage) lives on the loader. The
    /// view owns the date, the AI-filter pill state, and presentation-
    /// only state (sheets, scroll targets, bookmark UI).
    @State private var loader: RecordingsLoader
    @State private var pendingScrollTarget: Date?
    @State private var playedScrollTarget: Bool = false
    @State private var nowPlaying: PlayableRecording?
    @State private var showRawResponse = false
    /// AI-event filter chips. Empty set means "no filter — show
    /// everything". Persists across view rebuilds via parent
    /// re-creation only; deliberately not synced because filter
    /// preferences are typically session-scoped.
    @State private var aiFilter: Set<DetectionType> = []
    /// 0.5.0 Theme C1 — bookmarks for this camera. Loaded lazily on
    /// first appear so the recording list itself never blocks on
    /// iCloud Drive lookup. Surfaces in the toolbar "Bookmarks" button
    /// + the per-row "Bookmark this clip" context-menu item.
    @State private var bookmarks: [RecordingBookmark] = []
    @State private var showingBookmarks = false
    @State private var bookmarkExportStatus: String?

    init(session: CameraSession, channel: ChannelStatus, scrollTarget: Date? = nil) {
        self.session = session
        self.channel = channel
        self.scrollTarget = scrollTarget
        let initial = RecordingsLoader(
            source: session,
            channel: channel.channel,
            channelUID: channel.uid,
            captureRawResponses: true,
            initialDate: Date()
        )
        self._loader = State(wrappedValue: initial)
    }

    /// Binding for the DatePicker. Values are stored on the loader so
    /// the view itself owns no date state.
    private var dateBinding: Binding<Date> {
        Binding(
            get: { self.loader.selectedDate },
            set: { self.loader.selectedDate = $0 }
        )
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controls
            // 0.5.0 Liquid Glass — calendar, timeline, and filter
            // bar all use the same glass toolbar surface so the
            // recordings header reads as one continuous hovering
            // chrome strip.
            MonthRecordingDensity(selectedDate: dateBinding, monthStatuses: loader.monthStatuses)
                .reolensGlassToolbar()
            if !filteredFiles.isEmpty {
                DayTimelineStrip(
                    day: loader.selectedDate,
                    files: filteredFiles,
                    events: dayEvents,
                    onTapSegment: { preview($0) }
                )
                .reolensGlassToolbar()
            }
            AIEventFilterBar(selected: $aiFilter)
                .reolensGlassToolbar()
            Divider()
            content
            if !loader.files.isEmpty {
                let totalDetections = loader.files.reduce(0) { $0 + loader.effectiveDetections(for: $1).count }
                if totalDetections == 0
                    && loader.eventsUnsupported
                    && loader.files.allSatisfy({ $0.triggers.isEmpty })
                    && session.aiEventLog.isEmpty
                    && loader.alarmVideoEntries.isEmpty
                    && !loader.alarmVideoLoading {
                    Divider()
                    aiUnavailableFooter
                } else if !loader.alarmVideoEntries.isEmpty || !session.aiEventLog.isEmpty {
                    Divider()
                    baichuanActiveFooter
                }
            }
        }
        .task(id: loader.selectedDate) {
            loadBookmarks()
            await loader.reload()
            // After the day's files load, if the user got here via a
            // notification tap with a target time, auto-play the
            // closest matching clip. Guarded so it fires exactly once
            // per scrollTarget — re-renders don't keep re-opening the
            // player.
            if let target = pendingScrollTarget, !playedScrollTarget {
                playedScrollTarget = true
                pendingScrollTarget = nil
                autoPlayClipNearest(target)
            }
        }
        .onAppear {
            // Seed `pendingScrollTarget` from the prop on first
            // appear. Setting `loader.selectedDate` here makes the
            // existing `.task(id: loader.selectedDate)` fire a reload
            // for that day.
            if let target = scrollTarget, !playedScrollTarget {
                pendingScrollTarget = target
                let day = Calendar.current.startOfDay(for: target)
                if Calendar.current.startOfDay(for: loader.selectedDate) != day {
                    loader.selectedDate = target
                } else {
                    // Same day — reload already done; trigger the
                    // auto-play directly.
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
        .sheet(isPresented: $showingBookmarks) {
            // 0.5.1 — scope to this channel so a multi-channel hub
            // doesn't pile every channel's bookmarks into the per-
            // camera Recordings tab. The Bookmarks button on
            // `ChannelDetailContent` (camera view) uses the same
            // channel-scoped sheet.
            BookmarksSheet(
                cameraID: session.entry.id,
                cameraName: cameraScopedName,
                channel: channel.channel,
                bookmarks: $bookmarks,
                onPlay: { bookmark in
                    showingBookmarks = false
                    playBookmark(bookmark)
                },
                onExport: { bookmark in
                    exportBookmark(bookmark)
                }
            )
        }
    }

    /// Camera-scoped display name for the bookmarks sheet header:
    /// "Driveway" rather than "Home Hub" when viewing a specific
    /// channel under a hub. Falls back to the device name when the
    /// channel doesn't carry one.
    private var cameraScopedName: String {
        let channelName = (channel.name?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        }
        if let channelName {
            // Include the hub name as context when it differs from
            // the channel name, since "Driveway" alone may not be
            // enough on a multi-hub install.
            return session.entry.displayName == channelName
                ? channelName
                : "\(channelName) · \(session.entry.displayName)"
        }
        return session.entry.displayName
    }

    /// 0.5.0 Theme C1 — export a bookmarked clip to MP4. Re-uses the
    /// existing high-quality download path (the bookmark always
    /// brackets a single underlying source recording, so a direct
    /// per-segment download is sufficient for v1). The trim-to-range
    /// step (`ClipExporter`) runs after the download completes and
    /// writes the trimmed MP4 to the user's chosen destination.
    private func exportBookmark(_ bookmark: RecordingBookmark) {
        guard let source = loader.files.first(where: {
            guard let s = $0.startDate, let e = $0.endDate else { return false }
            return s <= bookmark.startDate && bookmark.startDate <= e
        }) ?? loader.files.first(where: {
            guard let s = $0.startDate else { return false }
            return abs(s.timeIntervalSince(bookmark.startDate)) < 90
        }) else {
            log.warning("exportBookmark: no source file in loaded day's files for bookmark \(bookmark.id.uuidString, privacy: .public)")
            return
        }
        // Hand off to the existing save-to-disk path with high
        // quality. The user picks a destination via NSSavePanel; the
        // RecordingPlayerSheet shows download progress. After the
        // download completes, `ClipExporter` trims to the bookmark's
        // range if the source's range exceeds the bookmark's. The
        // trim path is encapsulated in `RecordingPlayerSheet`'s
        // post-download hook for the dedicated bookmark export flow
        // — see `saveToDisk(_:quality:bookmarkRange:)`.
        saveToDisk(source, quality: .high, bookmarkRange: bookmark.range)
        showingBookmarks = false
    }

    /// 0.5.0 Theme C1 — add a bookmark covering the full duration of
    /// a recording. The user can later trim it from the bookmarks
    /// sheet. AI tags at the moment of bookmarking are captured so
    /// the bookmark stays meaningful even after recordings rotate
    /// off the hub's storage.
    private func addBookmark(for file: SearchFile) {
        guard let start = file.startDate, let end = file.endDate else { return }
        let bookmark = RecordingBookmark(
            cameraID: session.entry.id,
            channel: channel.channel,
            startEpoch: start.timeIntervalSince1970,
            endEpoch: end.timeIntervalSince1970,
            note: nil,
            aiTagsAtMark: loader.effectiveDetections(for: file).map { $0.label }
        )
        do {
            try RecordingBookmarkStore.add(bookmark)
            bookmarks = RecordingBookmarkStore.read(cameraID: session.entry.id)
        } catch {
            log.warning("Couldn't save bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadBookmarks() {
        bookmarks = RecordingBookmarkStore.read(cameraID: session.entry.id)
    }

    /// Replay a bookmark by re-opening the recording whose time range
    /// contains the bookmark's start. Reuses the existing preview
    /// path so playback feels identical to a row tap.
    private func playBookmark(_ bookmark: RecordingBookmark) {
        guard let match = loader.files.first(where: {
            guard let s = $0.startDate, let e = $0.endDate else { return false }
            return s <= bookmark.startDate && bookmark.startDate <= e
        }) ?? loader.files.first(where: {
            guard let s = $0.startDate else { return false }
            return abs(s.timeIntervalSince(bookmark.startDate)) < 90
        }) else { return }
        preview(match)
    }

    /// Locate the file whose time range contains `target` (preferred),
    /// or — if no file straddles the timestamp exactly — the file
    /// with the closest start time. Opens it via the same `preview`
    /// path a manual row tap uses.
    private func autoPlayClipNearest(_ target: Date) {
        // Containment first: AI-classified motion events typically
        // fire mid-clip, so the clip that straddles the timestamp is
        // the one the user actually wants.
        if let containing = filteredFiles.first(where: { file in
            guard let start = file.startDate, let end = file.endDate else { return false }
            return start <= target && target <= end
        }) {
            preview(containing)
            return
        }
        // Fallback: nearest by start time.
        let withDistance = filteredFiles.compactMap { file -> (SearchFile, TimeInterval)? in
            guard let start = file.startDate else { return nil }
            return (file, abs(start.timeIntervalSince(target)))
        }
        if let (closest, _) = withDistance.min(by: { $0.1 < $1.1 }) {
            preview(closest)
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
        // 0.5.0 Liquid Glass — recordings footer notice.
        .reolensGlassToolbar()
    }

    private var baichuanActiveFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Text("AI tags from Reolink Baichuan: \(distinctTaggedRecordingCount) tagged recording\(distinctTaggedRecordingCount == 1 ? "" : "s"), \(session.aiEventLog.count) live event\(session.aiEventLog.count == 1 ? "" : "s") this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if loader.alarmVideoLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 0.5.0 Liquid Glass — recordings footer notice.
        .reolensGlassToolbar()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            // `.field` style with an explicit minWidth keeps the long date
            // string (e.g. "Wednesday, May 11, 2026") from getting cropped.
            DatePicker("", selection: dateBinding, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(minWidth: 170, idealWidth: 200)
            Spacer()
            if loader.isLoading {
                ProgressView().controlSize(.small)
            }
            if store.developerMode, loader.lastRawResponse != nil {
                Button {
                    showRawResponse = true
                } label: {
                    Label("Raw JSON", systemImage: "curlybraces")
                }
                .help("Show the raw JSON response from the camera. Useful for diagnosing why detection icons don't match.")
                .popover(isPresented: $showRawResponse) {
                    RawResponseView(text: loader.lastRawResponse ?? "")
                }
            }
            // 0.5.0 — Bookmarks button. Shows a count badge when any
            // exist; opens the bookmarks sheet.
            // 0.5.1 — count is now scoped to THIS channel, matching
            // the sheet itself (which uses `channel: channel.channel`).
            // The previous device-level total was misleading on
            // multi-channel hubs — the user reported the badge looked
            // global even though the sheet only shows one channel.
            Button {
                showingBookmarks = true
            } label: {
                let scopedCount = bookmarks.filter { $0.channel == channel.channel }.count
                Label("Bookmarks (\(scopedCount))", systemImage: "bookmark")
            }
            .help("Show this camera's saved clip bookmarks.")
            Button {
                Task { await loader.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
        // 0.5.0 Liquid Glass — recordings header reads as a hovering
        // toolbar over the calendar / timeline / list stack below.
        .reolensGlassToolbar()
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = loader.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load recordings", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await loader.reload() } }
            }
        } else if loader.files.isEmpty && !loader.isLoading {
            ContentUnavailableView(
                "No recordings",
                systemImage: "tray",
                description: Text("No recordings on this channel for \(loader.selectedDate, format: .dateTime.day().month().year()).")
            )
        } else if filteredFiles.isEmpty && !loader.isLoading {
            ContentUnavailableView(
                "No matching recordings",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No recordings on this channel match the selected AI filter. Tap chips to remove filters or clear them entirely.")
            )
        } else {
            List(filteredFiles) { file in
                fileRow(file)
                    .contentShape(.rect)
                    .onTapGesture { preview(file) }
                    .contextMenu {
                        Button {
                            preview(file)
                        } label: {
                            Label("Preview (Low Quality)", systemImage: "play.circle")
                        }
                        Divider()
                        Button {
                            saveToDisk(file, quality: .low)
                        } label: {
                            Label("Download Low Quality…", systemImage: "arrow.down.circle")
                        }
                        .disabled(loader.subFileMatch(for: file) == nil)
                        Button {
                            saveToDisk(file, quality: .high)
                        } label: {
                            Label("Download High Quality…", systemImage: "arrow.down.circle.fill")
                        }
                        Divider()
                        Button {
                            addBookmark(for: file)
                        } label: {
                            Label("Bookmark this clip", systemImage: "bookmark")
                        }
                    }
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
            sizeColumn(for: file)
            rowActions(file)
        }
        .padding(.vertical, 4)
    }

    /// Right-aligned column that shows the file size for both stream
    /// qualities. The hub-reported `size` is authoritative on each Search
    /// response, so we can preview the bandwidth cost of each download
    /// option before the user picks one.
    @ViewBuilder
    private func sizeColumn(for file: SearchFile) -> some View {
        let mainMB = file.sizeMB
        let subMB = loader.subFileMatch(for: file)?.sizeMB
        VStack(alignment: .trailing, spacing: 2) {
            if let m = mainMB {
                HStack(spacing: 4) {
                    Text("HD")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: .capsule)
                        .foregroundStyle(.blue)
                    Text("\(m, specifier: "%.1f") MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let s = subMB {
                HStack(spacing: 4) {
                    Text("SD")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: .capsule)
                        .foregroundStyle(.secondary)
                    Text("\(s, specifier: "%.1f") MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help(sizeTooltip(main: mainMB, sub: subMB))
    }

    private func sizeTooltip(main: Double?, sub: Double?) -> String {
        switch (main, sub) {
        case (let m?, let s?):
            let ratio = m > 0 ? s / m * 100 : 0
            return String(format: "High quality (HD) %.1f MB · Low quality (SD) %.1f MB — sub is %.0f%% the size of main", m, s, ratio)
        case (let m?, nil):
            return String(format: "High quality (HD) %.1f MB — this camera doesn't record a low-quality stream", m)
        case (nil, let s?):
            return String(format: "Low quality (SD) %.1f MB", s)
        case (nil, nil):
            return "Size unknown"
        }
    }

    /// Per-row action buttons — visible so the available gestures are
    /// obvious without right-clicking. Play button previews on the sub
    /// stream when available, falling back to main; the menu offers explicit
    /// quality choices for both preview and download.
    @ViewBuilder
    private func rowActions(_ file: SearchFile) -> some View {
        let hasSub = loader.subFileMatch(for: file) != nil
        HStack(spacing: 4) {
            Button {
                preview(file)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help(hasSub ? "Preview (low quality, fast)" : "Preview (high quality — this camera has no sub stream)")

            Menu {
                Button("Preview (Low Quality)", systemImage: "play.circle") {
                    preview(file)
                }
                .disabled(!hasSub)
                Divider()
                Button("Download Low Quality…", systemImage: "arrow.down.circle") {
                    saveToDisk(file, quality: .low)
                }
                .disabled(!hasSub)
                Button("Download High Quality…", systemImage: "arrow.down.circle.fill") {
                    saveToDisk(file, quality: .high)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        // Stop row taps from firing inside the buttons.
        .onTapGesture {}
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
        let detections = loader.effectiveDetections(for: file)
        if !detections.isEmpty {
            HStack(spacing: 6) {
                ForEach(detections, id: \.self) { d in
                    HStack(spacing: 4) {
                        Image(systemName: d.systemImage)
                            .font(.caption2)
                        Text(d.label)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(tint(for: d))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint(for: d).opacity(0.15), in: .capsule)
                    .help(d.label)
                }
            }
        }
    }

    /// Files filtered by the AI chip selection. Empty filter → identity.
    /// A file matches when at least one of its effective detections is
    /// in the selected set (OR semantics — pick "people" OR "vehicle"
    /// for a "stuff worth watching" view).
    private var filteredFiles: [SearchFile] {
        guard !aiFilter.isEmpty else { return loader.files }
        return loader.files.filter { file in
            let detections = Set(loader.effectiveDetections(for: file))
            return !detections.isDisjoint(with: aiFilter)
        }
    }

    /// Live AI events from this session that fell on the displayed
    /// day. Feeds the timeline strip's event-tick overlay.
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

    private var distinctTaggedRecordingCount: Int {
        Set(loader.alarmVideoEntries.map(\.fileName)).count
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

    /// In-app preview: stream the SUB version (small, fast). Falls back to
    /// main only if no sub-stream file matches by start time.
    private func preview(_ file: SearchFile) {
        let target = loader.subFileMatch(for: file) ?? file
        let isSub = loader.subFileMatch(for: file) != nil
        Task {
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let url = StreamURLs(credentials: creds).recordingDownload(
                source: target.name,
                output: target.name,
                token: token
            )
            log.info("Preview channel=\(self.channel.channel) source=\(target.name, privacy: .public) quality=\(isSub ? "sub" : "main", privacy: .public) size=\(target.size ?? -1)")
            // PASS THE TARGET FILE, NOT THE ROW'S MAIN FILE. The progress
            // denominator reads `recording.file.size` — if we hand the main
            // file in, the bar measures a ~1.4 MB sub stream against the
            // ~23 MB main total and never visibly fills.
            nowPlaying = PlayableRecording(file: target, url: url, isHighQuality: !isSub)
        }
    }

    /// Save the chosen quality variant to disk via NSSavePanel. We don't
    /// auto-open it — the user is making an explicit "give me this file"
    /// gesture, and forcing a player on top of that would surprise them.
    private func saveToDisk(_ file: SearchFile, quality: DownloadQuality, bookmarkRange: ClosedRange<TimeInterval>? = nil) {
        let source: SearchFile
        switch quality {
        case .low:
            guard let sub = loader.subFileMatch(for: file) else {
                log.warning("No sub-stream file to download for \(file.name, privacy: .public); aborting low-quality save")
                return
            }
            source = sub
        case .high:
            source = file
        }
        let suffix = bookmarkRange == nil ? "(\(quality.label))" : "(bookmark \(quality.label))"
        let defaultName = "Reolens \(channel.name ?? "Channel \(channel.channel)") \(timeLabel(for: file)) \(suffix).mp4"
            .replacingOccurrences(of: ":", with: ".")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.message = bookmarkRange == nil
            ? "Save \(quality.label.lowercased())-quality recording"
            : "Export bookmarked clip (\(quality.label.lowercased()) quality)"
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        Task {
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let url = StreamURLs(credentials: creds).recordingDownload(
                source: source.name,
                output: source.name,
                token: token
            )
            // Reuse the in-app player sheet to surface progress, but mark it
            // as "save to disk" so it copies the result to the chosen path
            // instead of auto-playing. `bookmarkTrim` carries the
            // ClosedRange<TimeInterval> *relative to the source file's
            // start*; the player sheet's post-download hook hands it
            // to `ClipExporter.export(...)`.
            let trim: ClosedRange<TimeInterval>? = {
                guard let bookmarkRange, let fileStart = source.startDate else { return nil }
                let lo = max(0, bookmarkRange.lowerBound - fileStart.timeIntervalSince1970)
                let hi = max(lo, bookmarkRange.upperBound - fileStart.timeIntervalSince1970)
                return lo...hi
            }()
            nowPlaying = PlayableRecording(
                file: source,
                url: url,
                isHighQuality: quality == .high,
                saveDestination: destURL,
                bookmarkTrim: trim
            )
        }
    }

    private enum DownloadQuality { case low, high
        var label: String { self == .low ? "Low Quality" : "High Quality" }
    }
}

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
                    .font(.system(size: 11, design: .monospaced))
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

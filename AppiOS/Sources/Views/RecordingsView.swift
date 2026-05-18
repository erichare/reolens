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
    /// 0.6.0 Slice 13 — iOS bookmarks parity. Reuses the cross-
    /// platform `BookmarksSheet` from `AppShared` so this stays in
    /// sync with the macOS UX automatically.
    @State private var bookmarks: [RecordingBookmark] = []
    @State private var showingBookmarks = false
    /// 0.6.2 — status banner the BookmarksSheet renders below its
    /// list. Populated by the destination router as Save-to-Photos
    /// progresses ("Preparing…", "Saved to Photos.", permission
    /// denials, failure messages).
    @State private var bookmarksExportStatus: String?

    init(session: CameraSession, channel: ChannelStatus, scrollTarget: Date? = nil) {
        self.session = session
        self.channel = channel
        self.scrollTarget = scrollTarget
        let initial = RecordingsLoader(
            source: session,
            channel: channel.channel,
            channelUID: channel.uid,
            captureRawResponses: false,
            initialDate: Date(),
            cameraID: session.entry.id,
            cameraName: session.entry.displayName,
            index: RecordingIndex.shared
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
            .reolensGlassToolbar()
            // 0.6.2 a11y — explicit label so VoiceOver announces the
            // picker's role rather than the bare "Day" string. Matches
            // the day picker → filter chips → list focus order the
            // 0.6.2 CHANGELOG promises.
            .accessibilityLabel("Day picker")
            .accessibilityHint("Selects which day's recordings to show.")
            RecordingsScreenHeader(
                loader: loader,
                aiFilter: $aiFilter,
                filteredFiles: filteredFiles,
                onTapTimelineSegment: { file in
                    let sub = loader.subFileMatch(for: file)
                    playEntry(file: file, sub: sub, preferSub: true)
                }
            )
            Divider()
            content
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let scopedCount = bookmarks.filter { $0.channel == channel.channel }.count
                Button {
                    showingBookmarks = true
                } label: {
                    Label("Bookmarks (\(scopedCount))", systemImage: "bookmark")
                }
                .accessibilityLabel("Bookmarks")
            }
        }
        .task(id: loader.selectedDate) {
            // 0.6.0 TD-3a — bookmark enumeration moved out of the
            // per-day reload path. The per-camera bookmark list
            // doesn't change with the selected date, so re-reading
            // iCloud Drive on every date flip was wasted work.
            await loader.reload()
            if let target = pendingScrollTarget, !playedScrollTarget {
                playedScrollTarget = true
                pendingScrollTarget = nil
                autoPlayClipNearest(target)
            }
        }
        .task {
            // Runs once per view appear (no `id:`). Bookmarks update
            // after `bookmarkAndDownload(file:)` succeeds, so the
            // explicit re-read here only matters on first appear and
            // on iCloud-pushed bookmark changes from another device.
            await loadBookmarksLazily()
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
        .sheet(isPresented: $showingBookmarks) {
            BookmarksSheet(
                cameraID: session.entry.id,
                cameraName: cameraScopedName,
                channel: channel.channel,
                bookmarks: $bookmarks,
                onPlay: { bookmark in
                    showingBookmarks = false
                    playBookmark(bookmark)
                },
                onExport: { bookmark, destination in
                    // 0.6.2 — destination-aware export. iOS surfaces
                    // .photos via this dispatch. Share is driven by
                    // the `transferable` closure below, not by this
                    // switch. .savePanel / .dragOut are macOS routes
                    // the sheet's per-platform Menu hides on iOS so
                    // they should never reach this dispatch.
                    switch destination {
                    case .photos:
                        savePhotosClip(for: bookmark)
                    case .shareSheet, .savePanel, .dragOut:
                        log.warning("Unsupported export destination on iOS slice: \(String(describing: destination), privacy: .public)")
                    }
                },
                transferable: { bookmark in
                    guard let source = matchingSourceFile(for: bookmark) else { return nil }
                    return BookmarkClipTransferable.make(
                        bookmark: bookmark,
                        sourceFile: source,
                        cameraName: session.entry.displayName
                    )
                },
                exportStatus: $bookmarksExportStatus
            )
        }
    }

    /// Camera-scoped display name for the bookmarks sheet header.
    /// Mirrors the macOS view's helper of the same name so users
    /// see identical copy across platforms.
    private var cameraScopedName: String {
        let channelName = (channel.name?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        }
        if let channelName {
            return session.entry.displayName == channelName
                ? channelName
                : "\(channelName) · \(session.entry.displayName)"
        }
        return session.entry.displayName
    }

    private func loadBookmarks() {
        bookmarks = RecordingBookmarkStore.read(cameraID: session.entry.id)
    }

    /// 0.6.0 TD-3a — read bookmarks off the main thread so the
    /// first-render path doesn't block on iCloud Drive enumeration.
    /// `RecordingBookmarkStore.read` is synchronous file IO; running
    /// it inside a detached task and hopping back to the actor only
    /// to publish the result keeps the recordings list responsive on
    /// camera switches.
    private func loadBookmarksLazily() async {
        let cameraID = session.entry.id
        let read = await Task.detached(priority: .userInitiated) {
            RecordingBookmarkStore.read(cameraID: cameraID)
        }.value
        bookmarks = read
    }

    /// Replay a bookmark by finding the recording whose time range
    /// contains the bookmark's start. Reuses `playEntry` so playback
    /// feels identical to a row tap.
    private func playBookmark(_ bookmark: RecordingBookmark) {
        guard let match = matchingSourceFile(for: bookmark) else { return }
        let sub = loader.subFileMatch(for: match)
        playEntry(file: match, sub: sub, preferSub: true)
    }

    /// Locate the SearchFile whose range contains the bookmark's start
    /// (preferred) or that's within 90s. Used by both the play and the
    /// 0.6.2 Save-to-Photos export paths.
    private func matchingSourceFile(for bookmark: RecordingBookmark) -> SearchFile? {
        loader.files.first(where: {
            guard let s = $0.startDate, let e = $0.endDate else { return false }
            return s <= bookmark.startDate && bookmark.startDate <= e
        }) ?? loader.files.first(where: {
            guard let s = $0.startDate else { return false }
            return abs(s.timeIntervalSince(bookmark.startDate)) < 90
        })
    }

    /// 0.6.2 — Save-to-Photos route for the unified clip-export
    /// storyline. Trims the locally-cached source recording to the
    /// bookmark's range via `ClipExportCoordinator`, then hands the
    /// staged MP4 to `ClipPhotosSaver`. Status messages render in the
    /// BookmarksSheet's bottom banner via `bookmarksExportStatus`.
    ///
    /// Preconditions surfaced as user-readable errors rather than
    /// silent fails: matching SearchFile present (open the recording's
    /// day first), source startDate readable, local clip downloaded.
    private func savePhotosClip(for bookmark: RecordingBookmark) {
        guard let source = matchingSourceFile(for: bookmark) else {
            bookmarksExportStatus = "Open this recording's day in Recordings to export."
            return
        }
        guard let fileStart = source.startDate else {
            bookmarksExportStatus = "Couldn't read source recording start time."
            return
        }
        let localFile = BookmarkAutoDownloader.localFileURL(for: bookmark)
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            bookmarksExportStatus = "Clip is still downloading. Try again in a moment."
            return
        }
        let lo = max(0, bookmark.startEpoch - fileStart.timeIntervalSince1970)
        let hi = max(lo, bookmark.endEpoch - fileStart.timeIntervalSince1970)
        let request = ClipExportRequest(
            sources: [.init(url: localFile, range: lo...hi)],
            suggestedFilename: ClipExportCoordinator.suggestedFilename(
                cameraName: session.entry.displayName,
                start: bookmark.startDate
            )
        )
        bookmarksExportStatus = "Preparing clip…"
        Task {
            let outcome: String
            do {
                let staged = try await ClipExportCoordinator.stage(request)
                let result = await ClipPhotosSaver.save(videoFileURL: staged.stagedURL)
                switch result {
                case .saved:
                    outcome = "Saved to Photos."
                case .denied:
                    outcome = "Photos access denied. Enable it in Settings to save clips."
                case .unsupported:
                    outcome = "Save to Photos isn't supported on this platform."
                case .noFile:
                    outcome = "Couldn't prepare the clip file."
                case .failed(let msg):
                    outcome = "Couldn't save: \(msg)"
                }
            } catch {
                outcome = "Export failed: \(error.localizedDescription)"
            }
            bookmarksExportStatus = outcome
            // Drop the staging cache promptly after a save attempt so
            // the user's iOS device doesn't accumulate copies of every
            // clip they hand off to Photos. Synchronous file IO, but
            // the directory is small.
            ClipExportCoordinator.pruneStaging(olderThan: 30)
        }
    }

    /// Locate the file whose time range contains `target` (preferred)
    /// or the file with the closest start time. Plays via the same
    /// `playEntry` path a manual tap uses. 0.6.0 Slice 13b — search
    /// algorithm lives in shared `RecordingsAutoPlay`.
    private func autoPlayClipNearest(_ target: Date) {
        guard let match = RecordingsAutoPlay.bestMatch(for: target, in: filteredFiles) else { return }
        let sub = loader.subFileMatch(for: match)
        playEntry(file: match, sub: sub, preferSub: true)
    }

    @ViewBuilder
    private var content: some View {
        if loader.isLoading {
            ProgressView("Loading recordings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = loader.errorMessage {
            topPinnedEmptyState {
                ContentUnavailableView(
                    "Couldn't load recordings",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            }
        } else if loader.files.isEmpty {
            topPinnedEmptyState {
                ContentUnavailableView(
                    "No recordings",
                    systemImage: "moon.zzz",
                    description: Text("Nothing recorded on \(loader.selectedDate.formatted(date: .abbreviated, time: .omitted)).")
                )
            }
        } else if filteredFiles.isEmpty {
            topPinnedEmptyState {
                ContentUnavailableView(
                    "No matching recordings",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No recordings match the selected AI filter. Tap chips above to remove filters.")
                )
            }
        } else {
            List(filteredFiles) { file in
                row(for: file)
            }
            .listStyle(.plain)
        }
    }

    /// 0.6.0 Slice 13b — both shells now delegate filtering to the
    /// loader. `dayEvents` likewise lives on the loader.
    private var filteredFiles: [SearchFile] { loader.filtered(by: aiFilter) }

    /// 0.6.0 — pin the empty-state message to the top of the
    /// available space rather than letting `ContentUnavailable
    /// View` center itself in the full leftover height. The
    /// centered default left a visible void above the message
    /// which read as "the window is broken" rather than "nothing
    /// recorded yet". Mirrors the macOS helper of the same name.
    @ViewBuilder
    private func topPinnedEmptyState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.top, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func row(for file: SearchFile) -> some View {
        let sub = loader.subFileMatch(for: file)
        let detections = loader.effectiveDetections(for: file)
        // 0.6.0 — full-row tap target. Without `.contentShape(.rect)`
        // on the RecordingRow label, iOS treats the Button's hit
        // area as only the painted glyphs + text — Spacer regions
        // and the trailing size column read as "nothing here" and
        // taps there fall through to the List. Rect content-shape
        // covers the whole bounding box so a tap anywhere on the
        // row fires `playEntry`. Mirrors the All Recordings list's
        // `.contentShape(.rect).onTapGesture` pattern.
        Button {
            // Tap default: play the sub stream when available — much
            // smaller and faster to download than the main stream.
            // Falls back to main if no matching sub exists (some
            // single-stream cameras / certain firmware).
            Task { playEntry(file: file, sub: sub, preferSub: true) }
        } label: {
            RecordingRow(file: file, subFile: sub, detections: detections)
                .contentShape(.rect)
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
            aiTagsAtMark: file.triggers.map(\.rawValue),
            // 0.6.0 — persist the source file name so the launch-
            // time reconciler can re-enqueue the background download
            // without first doing a Search to find the file.
            sourceFileName: file.name
        )
        do {
            try RecordingBookmarkStore.add(bookmark)
            bookmarks = RecordingBookmarkStore.read(cameraID: session.entry.id)
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
        // 0.7.0 — unified shared player. Build both quality variants
        // up front so the player's in-header toggle is available
        // without re-resolving credentials mid-playback. `preferSub`
        // becomes the seed `initialQuality`; the user can still flip
        // in the player.
        Task {
            let credentials = await session.client.credentials
            let urls = StreamURLs(credentials: credentials)
            let token = await session.client.currentToken?.name
            let highVariant = PlayableRecording.Variant(
                url: urls.recordingDownload(source: file.name, output: file.name, token: token),
                file: file
            )
            let lowVariant = sub.map { sub in
                PlayableRecording.Variant(
                    url: urls.recordingDownload(source: sub.name, output: sub.name, token: token),
                    file: sub
                )
            }
            let initialQuality: RecordingQuality
            if preferSub, lowVariant != nil {
                initialQuality = .low
            } else if !preferSub {
                initialQuality = .high
            } else {
                initialQuality = lowVariant != nil ? .low : .high
            }
            let recording = PlayableRecording(
                id: "\(channel.channel):\(file.name)",
                displayName: file.name,
                cameraID: session.entry.id,
                cameraName: session.entry.displayName,
                channel: channel.channel,
                startDate: file.startDate,
                endDate: file.endDate,
                detections: loader.effectiveDetections(for: file),
                highQuality: highVariant,
                lowQuality: lowVariant,
                initialQuality: initialQuality
            )
            await MainActor.run {
                nowPlaying = recording
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

// 0.7.0 — the iOS-local `PlayableRecording`, `RecordingPlayerSheet`,
// and `AVPlayerHostView` types lived here until this rewrite. They
// are now centralized in `Sources/AppShared/Playback/` so iOS and
// macOS share one streaming player with identical behaviour, quality
// switching, and export destinations.

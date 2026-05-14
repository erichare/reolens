import SwiftUI
import OSLog
import ReolinkAPI
import ReolinkStreaming

private let log = Logger(subsystem: "com.reolens.app", category: "all-recordings-view")

/// 0.5.1 — Hub-scoped All Recordings view. Fans out a `Search` across
/// every channel on the given session, merges into one chronological
/// feed, and shows a camera-name pill on each row alongside the
/// existing AI-event detection chips.
///
/// Why a separate view rather than a flag on the existing per-camera
/// `RecordingsView`? The per-camera view is dense (calendar density,
/// timeline strip, dual-stream pairing, Baichuan alarm-video matching).
/// Folding cross-camera scope into that mass would make the code worse
/// for both code paths. Instead, the new view focuses on the cross-
/// camera UX — pills + simple chronological list — and the per-camera
/// view stays the place for deep single-camera browsing.
public struct AllRecordingsView: View {
    /// 0.5.1 — Sessions to aggregate across. Single-element for the
    /// hub-scoped path; multiple elements for cross-hub. The two
    /// initializers below pick the right value for each call site.
    public let sessions: [CameraSession]
    /// Optional initial camera filter — set by the sidebar when a
    /// specific camera is selected, so the user lands on the filtered
    /// list rather than the full feed.
    public let initiallySelectedCameras: Set<CameraFilterBar.CameraChannelKey>

    @Environment(CameraStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date = Date()
    @State private var rows: [ScopedRecording] = []
    @State private var bookmarks: [RecordingBookmark] = []
    @State private var isLoading = false
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var aiFilter: Set<DetectionType> = []
    @State private var cameraFilter: Set<CameraFilterBar.CameraChannelKey> = []
    @State private var nowPlaying: PreviewTarget?
    @State private var bookmarkToast: String?
    /// 0.5.1 — `EventSummarizer`-produced digest of the day's events.
    /// Recomputed after every reload; falls back to a count-based
    /// summary on devices without Apple Intelligence.
    @State private var digest: EventSummarizer.DailyDigest?
    /// 0.5.1 — Feed mode toggle. When `false` (the default), the
    /// list shows recordings for the selected day. When `true`, the
    /// list switches to "bookmarks only" — every saved bookmark
    /// across all days. Default flipped from `true` → `false` in a
    /// fix after the additive→mode-switch refactor: a fresh open
    /// was landing in bookmarks-only mode and hiding all recordings
    /// until the user tapped the toggle off.
    @State private var showBookmarks = false
    /// 0.5.1 — Bumped on every fresh reload so a slow in-flight
    /// stream from a previous date/filter selection doesn't write
    /// stale results into `rows` after the user moved on.
    @State private var loadGeneration = 0
    /// 0.5.1 — When non-nil, the view renders the cache hit
    /// immediately and runs a background refresh; the date label
    /// surfaces "Refreshing…" so the user knows fresh data is coming.
    @State private var cachedAt: Date?
    /// 0.6.0 Slice 11 — cross-day search. When `searchQuery` is non-
    /// empty, the feed switches from "this day's rows" to results
    /// queried out of `RecordingIndex`. The natural-language prompt is
    /// translated by `RecordingNLSearcher` into a structured query.
    @State private var searchQuery: String = ""
    @State private var indexedResults: [RecordingIndex.IndexedRecording] = []
    @State private var isSearching: Bool = false

    /// Convenience: shorthand to the first session (when present) so
    /// the bookmark/preview path can still reach a `CGIClient` for
    /// URL signing. Bookmark URLs are scoped to a single session, so
    /// callers pass the session via the `ScopedRecording.cameraKey`'s
    /// `deviceID` and we look up the matching session.
    private func session(for cameraKey: CameraFilterBar.CameraChannelKey) -> CameraSession? {
        sessions.first(where: { $0.entry.id == cameraKey.deviceID })
    }

    /// Lightweight playback target. Mirrors a slice of macOS's
    /// `PlayableRecording` so AllRecordingsView can stay cross-platform
    /// without dragging in the macOS view's heavier download-state type.
    private struct PreviewTarget: Identifiable, Hashable {
        let id: String
        let url: URL
        let title: String
    }

    /// 0.5.1 — Unified row type so bookmarks and recordings share one
    /// chronological feed. Each variant carries enough info to render
    /// the row + execute the row's primary action without crossing a
    /// type boundary in the body.
    fileprivate enum FeedItem: Identifiable, Hashable {
        case recording(ScopedRecording)
        case bookmark(RecordingBookmark, cameraKey: CameraFilterBar.CameraChannelKey)

        var id: String {
            switch self {
            case .recording(let r): return "rec:\(r.id)"
            case .bookmark(let b, _): return "bm:\(b.id.uuidString)"
            }
        }

        var startEpoch: TimeInterval {
            switch self {
            case .recording(let r): return r.file.startDate?.timeIntervalSince1970 ?? 0
            case .bookmark(let b, _): return b.startEpoch
            }
        }

        var cameraKey: CameraFilterBar.CameraChannelKey {
            switch self {
            case .recording(let r): return r.cameraKey
            case .bookmark(_, let key): return key
            }
        }

        var triggers: [DetectionType] {
            switch self {
            case .recording(let r): return r.file.triggers
            case .bookmark(let b, _):
                return b.aiTagsAtMark.compactMap { DetectionType(rawValue: $0) }
            }
        }
    }

    /// Hub-scoped — convenience for single-session callers.
    public init(
        session: CameraSession,
        initiallySelectedCameras: Set<CameraFilterBar.CameraChannelKey> = []
    ) {
        self.sessions = [session]
        self.initiallySelectedCameras = initiallySelectedCameras
    }

    /// Cross-hub — fan out across every supplied session. Each
    /// session keeps its own client + credentials; the loader bounds
    /// concurrency globally so multi-hub setups don't stampede the
    /// network.
    public init(
        sessions: [CameraSession],
        initiallySelectedCameras: Set<CameraFilterBar.CameraChannelKey> = []
    ) {
        self.sessions = sessions
        self.initiallySelectedCameras = initiallySelectedCameras
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
                .reolensGlassToolbar()
            if Calendar.current.isDateInToday(selectedDate), let digest {
                TodayDigestRow(digest: digest)
                    .reolensGlassToolbar()
            }
            AIEventFilterBar(selected: $aiFilter)
                .reolensGlassToolbar()
            CameraFilterBar(selected: $cameraFilter, cameras: availableCameras)
                .reolensGlassToolbar()
            Divider()
            content
        }
        .overlay(alignment: .bottom) {
            if let bookmarkToast {
                Text(bookmarkToast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.55)), in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: bookmarkToast)
        .onAppear {
            if cameraFilter.isEmpty, !initiallySelectedCameras.isEmpty {
                cameraFilter = initiallySelectedCameras
            }
        }
        .task(id: reloadKey) {
            await reload()
        }
        .searchable(
            text: $searchQuery,
            placement: searchFieldPlacement,
            prompt: "Search recordings — e.g. \"packages this week\""
        )
        .task(id: searchQuery) {
            await runIndexSearch()
        }
        .sheet(item: $nowPlaying) { rec in
            RecordingPreviewSheet(url: rec.url, title: rec.title) { nowPlaying = nil }
        }
    }

    // MARK: - Subviews

    private var controls: some View {
        HStack(spacing: 12) {
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
            if isStreaming || isLoading {
                ProgressView().controlSize(.small)
                if cachedAt != nil {
                    Text("Refreshing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(isOn: $showBookmarks) {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                    Text("\(bookmarks.count)")
                        .font(.caption.monospacedDigit())
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(bookmarks.isEmpty)
            .help(bookmarksToggleHelp)
            .accessibilityLabel(showBookmarks ? "Hide bookmarks" : "Show bookmarks")
            Button {
                Task { await reload(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isStreaming)
            .help("Refresh — drops the cache and refetches from every hub.")
            Text("\(filteredItems.count) item\(filteredItems.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // 0.5.1 — Close button so the All Recordings sheet (used
            // on macOS) always has a discoverable dismiss path
            // alongside the system's `.cancelAction` keyboard
            // shortcut. iPad / iPhone (where the view is pushed in a
            // NavigationStack) get the standard back button on top —
            // the explicit Close stays visible there too so the
            // affordance is uniform.
            Button("Close") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close All Recordings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !searchQuery.isEmpty {
            indexedSearchContent
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load recordings", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).font(.caption).textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await reload(force: true) } }
            }
        } else if showBookmarks, bookmarks.isEmpty, !isLoading, !isStreaming {
            ContentUnavailableView(
                "No bookmarks",
                systemImage: "bookmark.slash",
                description: Text("Long-press a recording and choose Bookmark this clip to save it for later. Toggle Bookmarks off to see recordings instead.")
            )
        } else if !showBookmarks, rows.isEmpty, !isLoading, !isStreaming {
            ContentUnavailableView(
                "No recordings",
                systemImage: "tray",
                description: Text("No recordings on this hub for \(selectedDate, format: .dateTime.day().month().year()).")
            )
        } else if filteredItems.isEmpty, !isLoading, !isStreaming {
            ContentUnavailableView(
                "No matching items",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Nothing matches the selected filters. Tap a chip to remove it.")
            )
        } else {
            List(filteredItems) { item in
                feedRow(item)
                    .contentShape(.rect)
                    .onTapGesture { activate(item) }
                    .contextMenu { contextMenu(for: item) }
                #if !os(macOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        switch item {
                        case .recording(let row):
                            Button {
                                bookmark(row)
                            } label: {
                                Label("Bookmark", systemImage: "bookmark.fill")
                            }
                            .tint(.accentColor)
                        case .bookmark(let bm, _):
                            Button(role: .destructive) {
                                removeBookmark(bm)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                #endif
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func feedRow(_ item: FeedItem) -> some View {
        switch item {
        case .recording(let row):
            recordingRow(row)
        case .bookmark(let bm, let key):
            bookmarkRow(bm, cameraKey: key)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FeedItem) -> some View {
        switch item {
        case .recording(let row):
            Button {
                preview(row)
            } label: {
                Label("Preview", systemImage: "play.circle")
            }
            Divider()
            Button {
                bookmark(row)
            } label: {
                Label("Bookmark this clip", systemImage: "bookmark")
            }
        case .bookmark(let bm, let key):
            Button {
                playBookmark(bm, cameraKey: key)
            } label: {
                Label("Play bookmarked clip", systemImage: "play.circle")
            }
            Divider()
            Button(role: .destructive) {
                removeBookmark(bm)
            } label: {
                Label("Delete bookmark", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func recordingRow(_ row: ScopedRecording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(timeLabel(epoch: row.file.startDate?.timeIntervalSince1970)).font(.body.monospacedDigit())
                HStack(spacing: 6) {
                    Label(row.cameraKey.label, systemImage: "video.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .reolensGlassChip(selected: false)
                    if let dur = row.file.durationSeconds {
                        Text(durationLabel(seconds: dur))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            detectionTags(row.file.triggers)
            if let mb = row.file.sizeMB {
                Text(String(format: "%.1f MB", mb))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var bookmarksToggleHelp: String {
        switch (bookmarks.isEmpty, showBookmarks) {
        case (true, _): return "No bookmarks yet — long-press / right-click a recording to bookmark it."
        case (false, true): return "Showing bookmarks only (\(bookmarks.count)). Toggle off to see recordings."
        case (false, false): return "Show bookmarks only (\(bookmarks.count) saved). Toggle to switch the feed from recordings to bookmarks."
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: RecordingBookmark, cameraKey: CameraFilterBar.CameraChannelKey) -> some View {
        let onSelectedDay = Calendar.current.isDate(bm.startDate, inSameDayAs: selectedDate)
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !onSelectedDay {
                        // 0.5.1 — cross-day bookmarks include the date
                        // so the merged feed stays readable when the
                        // user is browsing today's recordings but
                        // showing all-time bookmarks.
                        Text(bm.startDate, format: .dateTime.month(.abbreviated).day())
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeLabel(epoch: bm.startEpoch)).font(.body.monospacedDigit())
                }
                HStack(spacing: 6) {
                    Label(cameraKey.label, systemImage: "video.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .reolensGlassChip(selected: false)
                    Label("Bookmarked", systemImage: "bookmark.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .reolensGlassChip(selected: true, tint: .yellow)
                    Text(durationLabel(seconds: bm.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let note = bm.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            detectionTags(triggers(for: bm))
            // Local-file presence indicator — bookmarked clips
            // background-download via BookmarkAutoDownloader; the
            // checkmark tells the user the file is offline-ready.
            if BookmarkAutoDownloader.hasLocalClip(for: bm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Downloaded — available offline.")
                    .accessibilityLabel("Downloaded")
            }
        }
        .padding(.vertical, 4)
    }

    private func triggers(for bm: RecordingBookmark) -> [DetectionType] {
        bm.aiTagsAtMark.compactMap { DetectionType(rawValue: $0) }
    }

    @ViewBuilder
    private func detectionTags(_ triggers: [DetectionType]) -> some View {
        if !triggers.isEmpty {
            HStack(spacing: 4) {
                ForEach(triggers, id: \.self) { t in
                    Image(systemName: t.systemImage)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help(t.label)
                }
            }
        }
    }

    // MARK: - Derived state

    /// 0.5.1 — Build the camera filter bar's chip list across every
    /// session. Multi-hub setups still get a flat list, which keeps
    /// the UI consistent with the single-hub case. Labels prefix the
    /// hub name when there are multiple hubs so users can tell apart
    /// e.g. "Front Door · Driveway" vs. "Back Yard · Driveway".
    private var availableCameras: [CameraFilterBar.CameraChannelKey] {
        let needsHubPrefix = sessions.count > 1
        return sessions.flatMap { session in
            session.liveChannels.map { ch in
                let raw = ch.name ?? "Channel \(ch.channel + 1)"
                let label = needsHubPrefix ? "\(session.entry.displayName) · \(raw)" : raw
                return CameraFilterBar.CameraChannelKey(
                    deviceID: session.entry.id,
                    channel: ch.channel,
                    label: label
                )
            }
        }
    }

    /// 0.5.1 — The feed is a *mode*: either recordings-only (default)
    /// or bookmarks-only (when the Bookmarks toggle is on). The
    /// previous additive behavior (recordings + bookmarks
    /// intermixed) was confusing — selecting bookmarks just added
    /// rows rather than letting the user actually focus on saved
    /// clips. AI + camera filter pills still apply in both modes.
    fileprivate var filteredItems: [FeedItem] {
        var items: [FeedItem]
        if showBookmarks {
            // Bookmark camera keys must match the filter pill's keys
            // exactly (including the hub prefix on multi-hub setups)
            // so a camera filter narrows bookmarks correctly.
            let cameraByID = Dictionary(uniqueKeysWithValues:
                availableCameras.map { (Self.cameraIdentity($0), $0) }
            )
            items = bookmarks.compactMap { bm in
                let identity = Self.cameraIdentity(deviceID: bm.cameraID, channel: bm.channel)
                guard let key = cameraByID[identity] else { return nil }
                return .bookmark(bm, cameraKey: key)
            }
        } else {
            items = rows.map { .recording($0) }
        }
        items.sort { $0.startEpoch > $1.startEpoch }
        return items.filter { item in
            if !cameraFilter.isEmpty, !cameraFilter.contains(item.cameraKey) {
                return false
            }
            if !aiFilter.isEmpty {
                let triggers = item.triggers
                let matches = !triggers.isEmpty && triggers.contains(where: { aiFilter.contains($0) })
                if !matches { return false }
            }
            return true
        }
    }

    /// Stable identity tuple for matching bookmarks to camera filter
    /// keys without depending on the display label (which can vary
    /// across single-hub vs multi-hub mode).
    private static func cameraIdentity(_ key: CameraFilterBar.CameraChannelKey) -> String {
        cameraIdentity(deviceID: key.deviceID, channel: key.channel)
    }

    private static func cameraIdentity(deviceID: UUID, channel: Int) -> String {
        "\(deviceID.uuidString)|\(channel)"
    }

    private var sessionIDSet: Set<UUID> {
        Set(sessions.map(\.entry.id))
    }

    private var reloadKey: String {
        let day = ISO8601DateFormatter.string(
            from: Calendar.current.startOfDay(for: selectedDate),
            timeZone: .current,
            formatOptions: [.withFullDate]
        )
        let sessionIDs = sessionIDSet.map { $0.uuidString }.sorted().joined(separator: ",")
        return "\(sessionIDs)|\(day)"
    }

    // MARK: - Actions

    /// 0.5.1 — Two-phase reload. Cache hit paints the previous result
    /// instantly so the list never starts at blank; the loader then
    /// streams fresh per-channel batches in. `force` skips the cache
    /// path entirely (Refresh button + Retry on error).
    private func reload(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let day = selectedDate
        let sessionIDs = sessionIDSet
        // Bookmarks load synchronously off-disk (small JSON files).
        // No day filter — the Bookmarks toggle is the "show All
        // Bookmarks" gate; day filtering would defeat the feature.
        bookmarks = await loadAllBookmarks()

        // Cache phase — paint immediately when available, otherwise
        // clear the previous day's rows so the list doesn't show
        // stale content while the fresh stream is in flight.
        if !force, let cached = await RecordingsCache.shared.get(sessionIDs: sessionIDs, day: day) {
            rows = cached.rows
            cachedAt = cached.cachedAt
            // Stale cache still gets refreshed in the background;
            // fresh cache short-circuits the network entirely so the
            // refresh button (which sets `force: true`) is still
            // useful for explicit refetch.
            if !cached.isStale {
                refreshDigest(for: rows)
                return
            }
        } else {
            rows = []
            cachedAt = nil
        }

        let cameras = availableCameras
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.entry.id, $0) })
        let tasks: [AllRecordingsLoader.ChannelTask] = cameras.compactMap { cam in
            guard let session = sessionByID[cam.deviceID] else { return nil }
            return AllRecordingsLoader.ChannelTask(session: session, camera: cam)
        }

        isStreaming = true
        defer { isStreaming = false }
        var freshRows: [ScopedRecording] = []
        for await batch in AllRecordingsLoader.loadStreaming(tasks: tasks, day: day) {
            // Bail out if a newer reload has started while we were
            // streaming so we don't write stale results.
            guard generation == loadGeneration else { return }
            freshRows.append(contentsOf: batch)
            freshRows.sort { lhs, rhs in
                (lhs.file.startDate ?? .distantPast) > (rhs.file.startDate ?? .distantPast)
            }
            rows = freshRows
        }
        guard generation == loadGeneration else { return }
        await RecordingsCache.shared.set(sessionIDs: sessionIDs, day: day, rows: freshRows)
        cachedAt = Date()
        refreshDigest(for: freshRows)
        // 0.6.0 Slice 11 — feed the cross-day index. Group rows by
        // (camera, channel) so each `ingest` call is camera-scoped
        // and idempotent. Side-effect only; never blocks the UI.
        ingestStreamingResults(freshRows, day: day)
    }

    private func ingestStreamingResults(_ rows: [ScopedRecording], day: Date) {
        let cameraNameByKey = Dictionary(
            uniqueKeysWithValues: availableCameras.map { ($0, $0.label) }
        )
        let grouped = Dictionary(grouping: rows, by: \.cameraKey)
        for (cameraKey, scoped) in grouped {
            let files = scoped.map(\.file)
            let cameraID = cameraKey.deviceID
            let name = cameraNameByKey[cameraKey] ?? cameraKey.label
            let channel = cameraKey.channel
            Task {
                await RecordingIndex.shared.ingest(
                    files,
                    cameraID: cameraID,
                    cameraName: name,
                    channel: channel,
                    day: day
                )
            }
        }
    }

    // MARK: - 0.6.0 Cross-day index search

    /// Available cameras as `RecordingNLSearcher.CameraHint`s so the
    /// parser can resolve camera-name tokens in prompts.
    private var cameraHintsForSearch: [RecordingNLSearcher.CameraHint] {
        sessions.map { session in
            RecordingNLSearcher.CameraHint(
                cameraID: session.entry.id,
                name: session.entry.displayName
            )
        }
    }

    /// Search-field placement adapts to platform: a toolbar field on
    /// macOS, the system navigation-bar search affordance on iOS.
    private var searchFieldPlacement: SearchFieldPlacement {
        #if os(iOS)
        return .navigationBarDrawer(displayMode: .always)
        #else
        return .toolbar
        #endif
    }

    /// Translate the prompt to a structured query and run it against
    /// `RecordingIndex`. No-op when the search field is empty.
    private func runIndexSearch() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            indexedResults = []
            isSearching = false
            return
        }
        let searcher = RecordingNLSearcher()
        // 0.6.0 — use the on-device-model variant when available. It
        // falls back to the deterministic parser internally when
        // FoundationModels is unavailable, so this call is safe on
        // every device. The user prompt is the only thing the model
        // sees — no recording data crosses the boundary.
        var query = await searcher.planWithModel(
            prompt: trimmed,
            availableCameras: cameraHintsForSearch
        )
        // Merge the UI filter pills onto the parser's output so a
        // user's existing AI/camera selections compose with the NL
        // prompt rather than getting silently dropped.
        if !aiFilter.isEmpty {
            query.tagFilter = query.tagFilter.isEmpty
                ? aiFilter
                : query.tagFilter.intersection(aiFilter)
        }
        if !cameraFilter.isEmpty {
            let pillCameraIDs = Set(cameraFilter.map(\.deviceID))
            query.cameraIDs = query.cameraIDs.isEmpty
                ? pillCameraIDs
                : query.cameraIDs.intersection(pillCameraIDs)
        }
        isSearching = true
        defer { isSearching = false }
        let hits = await RecordingIndex.shared.query(query)
        indexedResults = hits
    }

    @ViewBuilder
    private var indexedSearchContent: some View {
        if isSearching, indexedResults.isEmpty {
            ContentUnavailableView {
                Label("Searching", systemImage: "magnifyingglass")
            } description: {
                Text("Looking across the last 30 days…").font(.caption)
            }
        } else if indexedResults.isEmpty {
            searchEmptyState
        } else {
            List(indexedResults) { hit in
                Button {
                    playIndexedHit(hit)
                } label: {
                    indexedRow(hit)
                }
                .buttonStyle(.plain)
                .contentShape(.rect)
                .accessibilityHint("Plays this recording.")
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top, spacing: 0) {
                searchPrivacyFooter
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
            }
        }
    }

    /// 0.6.1 — Empty / no-match state for NL search. Surfaces three
    /// concrete example prompts so the user discovers what the search
    /// understands without having to read the changelog. Mirrors the
    /// Spotlight pattern: when the search input is the focus, suggest
    /// shapes rather than leaving the screen blank.
    @ViewBuilder
    private var searchEmptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text(
                    "Nothing in the indexed window matches \"\(searchQuery)\". Try one of these:"
                )
            )
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.searchSuggestions, id: \.self) { suggestion in
                    Button {
                        searchQuery = suggestion
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .font(.body)
                            Spacer()
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Replaces your search with this suggestion.")
                }
            }
            .padding(.horizontal, 24)
            searchPrivacyFooter
                .padding(.horizontal, 24)
        }
    }

    /// 0.6.1 — Static suggestions surfaced when search returns nothing.
    /// Keep these aligned with what `RecordingNLSearcher` actually
    /// understands: tag, date, and a camera-ish hint.
    private static let searchSuggestions: [String] = [
        "packages this week",
        "vehicles yesterday",
        "people today"
    ]

    /// 0.6.1 — One-line footer explaining where the search runs.
    /// Reinforces AGENTS.md §5 — no recording data crosses the model
    /// boundary, the user's prompt is the only thing that does.
    @ViewBuilder
    private var searchPrivacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("Runs on-device when Apple Intelligence is available; falls back to a keyword parser. Recordings never leave the device.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func indexedRow(_ hit: RecordingIndex.IndexedRecording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hit.hasBookmark ? "bookmark.fill" : "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(hit.hasBookmark ? Color.yellow : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(timeLabel(epoch: hit.start.timeIntervalSince1970))
                    .font(.body.monospacedDigit())
                HStack(spacing: 6) {
                    Text(hit.start, format: .dateTime.month(.abbreviated).day())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Label(hit.cameraName, systemImage: "video.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .reolensGlassChip(selected: false)
                }
            }
            Spacer()
            detectionTags(Array(hit.detectionTags))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: hit))
    }

    /// 0.6.1 — Tapping a search hit jumps the user to the indexed
    /// recording's day in the existing per-day flow: switches
    /// `selectedDate` to the hit's day and clears the search field, so
    /// the standard list renders with the row visible. If the hit
    /// already has a bookmark (i.e. the clip is local) it could open
    /// the bookmark sheet — for 0.6.1 we keep the gesture simple and
    /// rely on the per-day list's tap-to-play to do the rest.
    private func playIndexedHit(_ hit: RecordingIndex.IndexedRecording) {
        selectedDate = Calendar.current.startOfDay(for: hit.start)
        searchQuery = ""
        indexedResults = []
    }

    private func accessibilityLabel(for hit: RecordingIndex.IndexedRecording) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short
        let when = dateFmt.string(from: hit.start)
        let tags = hit.detectionTags.isEmpty
            ? ""
            : ", tags: \(hit.detectionTags.map(\.rawValue).joined(separator: ", "))"
        let bookmarkSuffix = hit.hasBookmark ? ", bookmarked" : ""
        return "\(hit.cameraName) recording at \(when)\(tags)\(bookmarkSuffix). Double-tap to play."
    }

    private func refreshDigest(for rows: [ScopedRecording]) {
        if Calendar.current.isDateInToday(selectedDate) {
            let perCamera = perCameraSummaries(for: rows)
            Task {
                let new = await EventSummarizer.shared.summarize(
                    day: selectedDate,
                    perCamera: perCamera
                )
                await MainActor.run { digest = new }
            }
        } else {
            digest = nil
        }
    }

    /// 0.5.1 — Read every bookmark across every camera in scope, no
    /// day filter. The user's ask was an "All Bookmarks" view; a
    /// per-day filter made the Bookmarks toggle look broken because
    /// most users don't have bookmarks specifically on today's date.
    /// Day-mismatched bookmarks render with a date prefix on the row
    /// so the cross-day mix stays readable.
    private func loadAllBookmarks() async -> [RecordingBookmark] {
        let cameraIDs = sessions.map { $0.entry.id }
        return await Task.detached(priority: .userInitiated) {
            cameraIDs.flatMap { id in
                RecordingBookmarkStore.read(cameraID: id)
            }
        }.value
    }

    private func perCameraSummaries(for rows: [ScopedRecording]) -> [EventSummarizer.CameraSummary] {
        let grouped = Dictionary(grouping: rows, by: \.cameraKey)
        return availableCameras.map { cam in
            let cameraRows = grouped[cam] ?? []
            var triggers: [DetectionType: Int] = [:]
            for r in cameraRows {
                for t in r.file.triggers {
                    triggers[t, default: 0] += 1
                }
            }
            return EventSummarizer.CameraSummary(
                cameraID: cam.deviceID,
                cameraName: cam.label,
                totalClips: cameraRows.count,
                triggers: triggers
            )
        }
    }

    /// 0.5.1 — Row-tap dispatch: recordings preview live; bookmarks
    /// play their local clip when present, otherwise hit the network
    /// like a fresh preview.
    private func activate(_ item: FeedItem) {
        switch item {
        case .recording(let row): preview(row)
        case .bookmark(let bm, let key): playBookmark(bm, cameraKey: key)
        }
    }

    private func playBookmark(_ bm: RecordingBookmark, cameraKey: CameraFilterBar.CameraChannelKey) {
        // 1. Local copy wins — offline, no network, fastest start.
        let localURL = BookmarkAutoDownloader.localFileURL(for: bm)
        if FileManager.default.fileExists(atPath: localURL.path) {
            nowPlaying = PreviewTarget(
                id: "bm:\(bm.id.uuidString)",
                url: localURL,
                title: "\(cameraKey.label) — bookmark"
            )
            return
        }
        // 2. No local file. Stream from the camera right away (same
        //    HTTP-progressive-download path the normal `preview()`
        //    flow uses) and kick the background download in parallel
        //    so the next play is offline. The previous behaviour
        //    just toasted "download in progress" with no video and
        //    no progress indication, which left users staring at
        //    nothing.
        guard let session = session(for: cameraKey) else {
            bookmarkToast = "Camera not connected — open it once, then try again."
            scheduleBookmarkToastDismiss()
            return
        }
        // Resolve the source filename. Newly-created bookmarks
        // persist it on the schema; legacy bookmarks may not, in
        // which case we look for a row in the currently-loaded feed
        // whose time range contains the bookmark's start.
        let resolvedFileName: String? = bm.sourceFileName
            ?? rows.first(where: { row in
                guard row.cameraKey == cameraKey,
                      let start = row.file.startDate,
                      let end = row.file.endDate else { return false }
                return start <= bm.startDate && bm.startDate <= end
            })?.file.name
        guard let fileName = resolvedFileName else {
            bookmarkToast = "Open this camera at \(bm.startDate.formatted(date: .abbreviated, time: .omitted)) to play this bookmark."
            scheduleBookmarkToastDismiss()
            return
        }
        Task { @MainActor in
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let streamURL = StreamURLs(credentials: creds).recordingDownload(
                source: fileName,
                output: fileName,
                token: token
            )
            // Open the player immediately on the streaming URL —
            // user sees video right away.
            nowPlaying = PreviewTarget(
                id: "bm:\(bm.id.uuidString)",
                url: streamURL,
                title: "\(cameraKey.label) — bookmark"
            )
            // Fire-and-forget the background download for offline-
            // next-time. Idempotent via `tasksInFlight` so it's safe
            // to call on every tap.
            Task {
                _ = await BookmarkAutoDownloader.shared.enqueueIfMissing(
                    bookmark: bm,
                    session: session,
                    fallbackFileName: fileName
                )
            }
        }
    }

    private func scheduleBookmarkToastDismiss() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { bookmarkToast = nil }
        }
    }

    private func removeBookmark(_ bm: RecordingBookmark) {
        // Optimistic UI: drop from the in-memory list immediately
        // so the row disappears without waiting on disk IO. The
        // full-cleanup helper handles the persistent side
        // (cancelling any in-flight download, deleting the local
        // clip file, removing the JSON entry).
        bookmarks.removeAll { $0.id == bm.id }
        Task {
            await BookmarkAutoDownloader.shared.removeBookmark(bm)
        }
    }

    private func preview(_ row: ScopedRecording) {
        // 0.5.1 — multi-hub: resolve the originating session by the
        // row's `deviceID` so we sign the URL with the right hub's
        // credentials. Falls through silently if the session has
        // gone away (e.g. user removed the camera mid-browse).
        guard let session = session(for: row.cameraKey) else { return }
        let file = row.file
        Task {
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let url = StreamURLs(credentials: creds).recordingDownload(
                source: file.name,
                output: file.name,
                token: token
            )
            nowPlaying = PreviewTarget(id: row.id, url: url, title: row.cameraKey.label)
        }
    }

    private func bookmark(_ row: ScopedRecording) {
        guard let session = session(for: row.cameraKey) else { return }
        let file = row.file
        let bookmark = RecordingBookmark(
            cameraID: session.entry.id,
            channel: row.cameraKey.channel,
            startEpoch: file.startDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            endEpoch: file.endDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            note: nil,
            aiTagsAtMark: file.triggers.map(\.rawValue)
        )
        Task {
            do {
                try RecordingBookmarkStore.add(bookmark)
            } catch {
                log.warning("Bookmark save failed: \(String(describing: error), privacy: .public)")
            }
            // 0.5.1 — auto-download so the clip is available offline.
            // BookmarkAutoDownloader gates the actual URLSession on
            // Wi-Fi reachability.
            let token = await session.client.currentToken?.name
            let creds = await session.client.credentials
            let url = StreamURLs(credentials: creds).recordingDownload(
                source: file.name,
                output: file.name,
                token: token
            )
            await BookmarkAutoDownloader.shared.enqueue(bookmark: bookmark, sourceURL: url)
            await MainActor.run {
                bookmarks.append(bookmark)
                bookmarkToast = "Bookmarked — downloading…"
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { bookmarkToast = nil }
        }
    }

    // MARK: - Helpers

    private func timeLabel(epoch: TimeInterval?) -> String {
        guard let epoch, epoch > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    private func durationLabel(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

/// 0.5.1 — Inline digest row shown at the top of `AllRecordingsView`
/// when the current day is being browsed. Tries on-device
/// FoundationModels first; falls back to a deterministic count-based
/// summary otherwise. Either way, this is purely on-device — no
/// network calls. The `source` chip lets the user see at a glance
/// whether they're looking at the AI-generated text or the basic
/// fallback.
private struct TodayDigestRow: View {
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

/// Cross-platform preview sheet for the All Recordings list.
///
/// For HTTP URLs (camera CGI `cmd=Download`) we route through
/// `RecordingDownloader` first: AVPlayer's progressive-HTTP code path
/// gives up on Reolink's CGI response (no `Accept-Ranges`, omitted
/// `Content-Type`, no `Content-Length` on Home Hub Pro) and renders
/// a slashed-player icon. Downloading the whole clip to a cache file
/// first and then handing that local URL to `AVPlayer` always works
/// and is a no-op on the second tap thanks to the downloader's
/// content-stable disk cache.
///
/// For `file://` URLs we play directly — the bookmark path passes a
/// local file that's already on disk.
private struct RecordingPreviewSheet: View {
    let url: URL
    let title: String
    let onDismiss: () -> Void

    @State private var downloader = RecordingDownloader()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Close", action: onDismiss).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: url) {
            // Local files (already-downloaded bookmarks) play
            // directly; only remote CGI URLs go through the
            // downloader.
            if !url.isFileURL {
                downloader.start(url: url)
            }
        }
        .onDisappear { downloader.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(AVKit)
        if url.isFileURL {
            AVPlayerStreamView(url: url)
                .frame(minWidth: 480, minHeight: 270)
        } else {
            switch downloader.state {
            case .idle, .downloading:
                downloadingPanel
            case .ready:
                if let localURL = downloader.localURL {
                    AVPlayerStreamView(url: localURL)
                        .frame(minWidth: 480, minHeight: 270)
                } else {
                    ContentUnavailableView("Couldn't open clip", systemImage: "play.slash")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't play this recording", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.caption).textSelection(.enabled)
                } actions: {
                    Button("Retry") { downloader.start(url: url) }
                }
            }
        }
        #else
        ContentUnavailableView("Playback unavailable", systemImage: "play.slash")
        #endif
    }

    private var downloadingPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Loading recording…").font(.headline)
            let received = downloader.bytesReceived
            let total = max(downloader.totalBytes, received)
            if total > 0 {
                ProgressView(value: min(1.0, Double(received) / Double(max(total, 1))))
                    .frame(maxWidth: 320)
                Text("\(byteString(received)) of \(byteString(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.regular)
                Text("Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

#if canImport(AVKit)
import AVKit

private struct AVPlayerStreamView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let item = AVPlayerItem(url: url)
                let p = AVPlayer(playerItem: item)
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}
#endif

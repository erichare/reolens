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

    @Environment(CameraStore.self) private var store
    @State private var selectedDate: Date = Date()
    /// Canonical list shown to the user. Sourced from a Search of the **main**
    /// stream — that's the high-quality recording the hub actually stores.
    @State private var files: [SearchFile] = []
    /// Sub-stream Search results. Matched against main rows by time-range
    /// overlap because Reolink doesn't synchronize the two streams to the
    /// second — observed offsets of ±2-6s and occasionally more, so we can't
    /// use an exact `startTime` fingerprint.
    @State private var subFiles: [SearchFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nowPlaying: PlayableRecording?
    @State private var rawResponse: String?
    @State private var showRawResponse = false
    @State private var eventLog: [HubEvent] = []
    @State private var eventsUnsupported = false
    /// Baichuan-delivered alarm-tagged recording info from `findAlarmVideo` on
    /// the hub. Stored as a flat list because the hub emits ONE block per
    /// alarm tag — the same recording can produce e.g. two blocks
    /// (`alarmType=md`, then `alarmType=people`) sharing the same `fileName`
    /// and time range. Aggregation across all blocks happens in
    /// `effectiveDetections`.
    @State private var alarmVideoEntries: [BaichuanAlarmVideoFile] = []
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
                    && alarmVideoEntries.isEmpty
                    && !alarmVideoLoading {
                    Divider()
                    aiUnavailableFooter
                } else if !alarmVideoEntries.isEmpty || !session.aiEventLog.isEmpty {
                    Divider()
                    baichuanActiveFooter
                }
            }
        }
        .task(id: selectedDate) {
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
            Text("AI tags from Reolink Baichuan: \(distinctTaggedRecordingCount) tagged recording\(distinctTaggedRecordingCount == 1 ? "" : "s"), \(session.aiEventLog.count) live event\(session.aiEventLog.count == 1 ? "" : "s") this session.")
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

    private var controls: some View {
        HStack(spacing: 12) {
            // `.field` style with an explicit minWidth keeps the long date
            // string (e.g. "Wednesday, May 11, 2026") from getting cropped.
            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(minWidth: 170, idealWidth: 200)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if store.developerMode, rawResponse != nil {
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
                        .disabled(subFileMatch(for: file) == nil)
                        Button {
                            saveToDisk(file, quality: .high)
                        } label: {
                            Label("Download High Quality…", systemImage: "arrow.down.circle.fill")
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
        let subMB = subFileMatch(for: file)?.sizeMB
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
        let hasSub = subFileMatch(for: file) != nil
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
        let detections = effectiveDetections(for: file)
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

    private func effectiveDetections(for file: SearchFile) -> [DetectionType] {
        if !file.triggers.isEmpty { return file.triggers }

        var matches: [DetectionType] = []
        var seen = Set<DetectionType>()

        // 1. Best source: Baichuan's findAlarmVideo response, matched by
        //    TIME-RANGE OVERLAP. The CGI `Search` and Baichuan `findAlarmVideo`
        //    APIs use different file-name encodings, but both report
        //    start/end timestamps in the camera's local time, so an
        //    overlapping range is a reliable correspondence.
        for av in alarmVideosOverlapping(file: file) {
            for d in av.detections where seen.insert(d).inserted {
                matches.append(d)
            }
        }
        if !matches.isEmpty { return matches }

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

    /// Find every `BaichuanAlarmVideoFile` whose time range overlaps with the
    /// given CGI `SearchFile`. Two ranges overlap iff `avStart < fileEnd`
    /// and `avEnd > fileStart`. We use half-open semantics so a Baichuan
    /// entry that ends exactly at the file's start is treated as the previous
    /// event, not this one.
    private func alarmVideosOverlapping(file: SearchFile) -> [BaichuanAlarmVideoFile] {
        guard let fileStart = file.startDate, let fileEnd = file.endDate else {
            return alarmVideoEntries.filter { $0.fileName == file.name }
        }
        return alarmVideoEntries.filter { av in
            if av.fileName == file.name { return true }
            guard let avStart = av.startDate, let avEnd = av.endDate else { return false }
            return avStart < fileEnd && avEnd > fileStart
        }
    }

    /// Distinct alarm-tagged recordings — multiple `<alarmVideo>` blocks with
    /// the same fileName count as one. Used for the footer label.
    private var distinctTaggedRecordingCount: Int {
        Set(alarmVideoEntries.map(\.fileName)).count
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

        // Sequence main → sub. Reolink Home Hub Pro returns `rcv failed`
        // (rspCode=-17) when two `Search` commands hit it concurrently on
        // the same channel — running them serially is reliable. Sub failure
        // is non-fatal: not every camera produces a sub-stream recording
        // (notably battery cameras), so we just skip the low-quality
        // preview/download path for those rows.
        let mainOutcome = await fetchSearchResults(channel: channel.channel, streamType: "main", start: start, end: end, captureRaw: true)
        switch mainOutcome {
        case .success(let mainFiles, let raw):
            rawResponse = raw
            files = mainFiles.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        case .failure(let message):
            errorMessage = message
            files = []
        }

        let subOutcome = await fetchSearchResults(channel: channel.channel, streamType: "sub", start: start, end: end, captureRaw: false)
        switch subOutcome {
        case .success(let subResults, _):
            subFiles = subResults.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            log.info("Sub-stream Search returned \(subResults.count) files")
            if case .success(let mainResults, _) = mainOutcome, !mainResults.isEmpty {
                let matched = mainResults.filter { subFileMatchFromList(for: $0, subs: subFiles) != nil }
                log.info("  main↔sub time-overlap matches: \(matched.count) of \(mainResults.count)")
            }
        case .failure(let message):
            log.info("Sub-stream Search unavailable on channel \(self.channel.channel): \(message, privacy: .public). Falling back to main-only.")
            subFiles = []
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

        // Reolink Home Hubs route findAlarmVideo to a paired camera by its
        // PER-CAMERA UID, not the hub UID. The CGI `GetChannelstatus` response
        // gives us that mapping (each ChannelStatus has a `uid` field).
        // Baichuan msg 114 returns only the hub UID and is therefore wrong
        // for this purpose — we keep it as a last-resort fallback in case
        // `GetChannelstatus` didn't populate uid for some firmware.
        let uid: String
        if let cgiUID = channel.uid, !cgiUID.isEmpty {
            uid = cgiUID
            log.info("Using per-channel UID from GetChannelstatus for channel=\(self.channel.channel): \(cgiUID, privacy: .public)")
        } else {
            uid = await client.fetchUID(channelID: UInt8(channel.channel))
            log.info("Fallback: Baichuan-fetched UID for channel=\(self.channel.channel): \(uid.isEmpty ? "<empty>" : uid, privacy: .public)")
        }

        do {
            let files = try await client.findAlarmVideos(
                channel: UInt8(channel.channel),
                start: start,
                end: end,
                streamType: "main",
                uid: uid
            )
            alarmVideoEntries = files
            log.info("findAlarmVideo channel=\(self.channel.channel) entries=\(files.count) tags=\(files.flatMap { $0.detections }.map { $0.label }.joined(separator: ","), privacy: .public)")
            // Dump per-entry detail so we can diagnose name/time mismatches
            // against the CGI Search rows shown in the UI.
            for f in files {
                let startStr = f.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                let endStr = f.endDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                log.info("  baichuan-file: name=\(f.fileName, privacy: .public) start=\(startStr, privacy: .public) end=\(endStr, privacy: .public) alarmType=\(f.alarmType, privacy: .public)")
            }
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

    /// In-app preview: stream the SUB version (small, fast). Falls back to
    /// main only if no sub-stream file matches by start time.
    private func preview(_ file: SearchFile) {
        let target = subFileMatch(for: file) ?? file
        let isSub = subFileMatch(for: file) != nil
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
    private func saveToDisk(_ file: SearchFile, quality: DownloadQuality) {
        let source: SearchFile
        switch quality {
        case .low:
            guard let sub = subFileMatch(for: file) else {
                log.warning("No sub-stream file to download for \(file.name, privacy: .public); aborting low-quality save")
                return
            }
            source = sub
        case .high:
            source = file
        }
        let defaultName = "Reolens \(channel.name ?? "Channel \(channel.channel)") \(timeLabel(for: file)) (\(quality.label)).mp4"
            .replacingOccurrences(of: ":", with: ".")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.message = "Save \(quality.label.lowercased())-quality recording"
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
            // instead of auto-playing.
            nowPlaying = PlayableRecording(
                file: source,
                url: url,
                isHighQuality: quality == .high,
                saveDestination: destURL
            )
        }
    }

    /// Find the sub-stream file whose time range overlaps the given main
    /// file. Reolink doesn't sync stream timestamps to the second (observed
    /// offsets ±2-6s), so exact matching fails. Overlap is robust to these
    /// offsets and to slightly different segment boundaries between the two
    /// stream chunkers.
    private func subFileMatch(for file: SearchFile) -> SearchFile? {
        subFileMatchFromList(for: file, subs: subFiles)
    }

    private func subFileMatchFromList(for file: SearchFile, subs: [SearchFile]) -> SearchFile? {
        guard let mainStart = file.startDate, let mainEnd = file.endDate else { return nil }
        // Take the sub with the largest temporal intersection — protects
        // against the rare case where a long main file overlaps several
        // shorter sub segments (we want the one that most-likely contains
        // the same content).
        var best: (sub: SearchFile, overlap: TimeInterval)? = nil
        for sub in subs {
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

    private enum DownloadQuality { case low, high
        var label: String { self == .low ? "Low Quality" : "High Quality" }
    }

    /// Per-stream Search result with raw JSON for diagnostics.
    private enum SearchOutcome {
        case success([SearchFile], rawPretty: String)
        case failure(String)
    }

    private func fetchSearchResults(channel: Int, streamType: String, start: Date, end: Date, captureRaw: Bool) async -> SearchOutcome {
        let command = Commands.search(
            channel: channel,
            onlyStatus: false,
            streamType: streamType,
            start: start,
            end: end
        )
        do {
            let raw = try await session.client.sendCapturingRaw(command)
            let pretty = captureRaw ? (prettyPrint(raw) ?? String(data: raw, encoding: .utf8) ?? "<binary>") : ""
            if captureRaw {
                log.info("Search raw response (channel=\(channel) stream=\(streamType, privacy: .public)):\n\(pretty, privacy: .public)")
            } else {
                log.debug("Sub Search returned \(raw.count) bytes for channel=\(channel)")
            }
            let envelopes = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: raw)
            guard let firstValue = envelopes.first?.value else {
                return .failure("Empty response from camera")
            }
            let result = firstValue.SearchResult.File ?? []
            return .success(result, rawPretty: pretty)
        } catch {
            return .failure("\(error)")
        }
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

    init(file: SearchFile, url: URL, isHighQuality: Bool, saveDestination: URL? = nil) {
        self.file = file
        self.url = url
        self.isHighQuality = isHighQuality
        self.saveDestination = saveDestination
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
            downloader.cleanupTempFile()
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
                AVPlayerHostView(url: localURL)
                    .frame(minWidth: 720, minHeight: 405)
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

import SwiftUI
import ReolinkAPI
import UniformTypeIdentifiers

/// 0.5.0 Theme C1 — bookmark list + delete + export. Presented from
/// `RecordingsView`, `ChannelDetailContent`, and `SingleChannelView`;
/// writes back through `RecordingBookmarkStore`.
///
/// 0.5.1: moved from `App/Views/BookmarksSheet.swift` into AppShared
/// so the iOS app can present the same UI from `SingleChannelView`.
/// Cross-platform from inception — the `onExport` callback stays
/// optional so iOS callers (which don't have an `NSSavePanel`-style
/// export pipeline) can omit it cleanly.
public struct BookmarksSheet: View {

    public let cameraID: UUID
    public let cameraName: String
    /// 0.5.1 — When non-nil, only bookmarks on this channel render in
    /// the list. Callers on per-channel views (camera Live / Recordings
    /// tab) pass the focused channel so the sheet shows just *this*
    /// camera's bookmarks; callers viewing a hub as a whole pass nil
    /// to see every channel's bookmarks at once.
    public let channel: Int?
    @Binding public var bookmarks: [RecordingBookmark]
    public let onPlay: (RecordingBookmark) -> Void
    /// 0.5.0 Theme C1 — export-trimmed-MP4 callback. Routed to
    /// `RecordingsView.exportBookmark(_:to:)` which knows about the
    /// matching `SearchFile` and the camera's CGI client.
    ///
    /// 0.6.2 — the callback now carries a `ClipExportDestination` so
    /// the same Export Menu surfaces Save to Photos / Share / drag-out
    /// / Save As… without each platform inventing its own routing.
    /// Optional so the sheet can render in contexts (previews, tests)
    /// without an export pipeline.
    public let onExport: ((RecordingBookmark, ClipExportDestination) -> Void)?
    /// 0.6.2 — share-sheet route. The parent builds a
    /// `BookmarkClipTransferable` (or returns nil if the bookmark
    /// can't be shared yet — usually because the local clip is still
    /// downloading or the source recording isn't loaded). The sheet
    /// renders a `ShareLink` for non-nil results.
    ///
    /// Separate closure from `onExport` because `ShareLink` consumes
    /// a `Transferable` directly — the system drives the staging via
    /// the Transferable's `FileRepresentation` rather than the parent
    /// having to react to a destination tap. Cleaner UX (no extra tap
    /// to confirm; the system's own "Preparing…" UI runs).
    public let transferable: ((RecordingBookmark) -> BookmarkClipTransferable?)?
    /// 0.6.2 — status banner shown below the bookmark list. The parent
    /// view's `onExport` closure is the producer ("Preparing…",
    /// "Saved to Photos", "Permission denied", …); the sheet just
    /// renders. Binding rather than internal `@State` because the
    /// work happens outside the sheet's body and the consumer (the
    /// parent's destination router) needs to set it.
    @Binding public var exportStatus: String?

    @Environment(\.dismiss) private var dismiss
    /// 0.6.0 — confirmation prompt before an explicit Delete-button
    /// tap removes a bookmark. Swipe-to-delete on iOS still works
    /// without a prompt (the swipe gesture itself is the
    /// confirmation), but a discoverable button in the row needs an
    /// intermediate "are you sure?" step so an accidental click
    /// doesn't lose a saved clip.
    @State private var pendingDelete: RecordingBookmark?

    public init(
        cameraID: UUID,
        cameraName: String,
        channel: Int? = nil,
        bookmarks: Binding<[RecordingBookmark]>,
        onPlay: @escaping (RecordingBookmark) -> Void,
        onExport: ((RecordingBookmark, ClipExportDestination) -> Void)? = nil,
        transferable: ((RecordingBookmark) -> BookmarkClipTransferable?)? = nil,
        exportStatus: Binding<String?> = .constant(nil)
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.channel = channel
        self._bookmarks = bookmarks
        self.onPlay = onPlay
        self.onExport = onExport
        self.transferable = transferable
        self._exportStatus = exportStatus
    }

    /// 0.5.1 — Honor the optional `channel` filter and the user's
    /// "newest first" expectation in one place so every consumer of
    /// the list (empty state, row enumeration, delete index lookup)
    /// stays consistent.
    private var visibleBookmarks: [RecordingBookmark] {
        let scoped = channel.map { ch in bookmarks.filter { $0.channel == ch } } ?? bookmarks
        return scoped.sorted(by: { $0.startEpoch > $1.startEpoch })
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bookmarks")
                        .font(.title3.weight(.semibold))
                    Text(cameraName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            // 0.5.0 Liquid Glass — sheet header reads as a hovering
            // chrome strip over the list below.
            .reolensGlassPanel()
            Divider()
            if visibleBookmarks.isEmpty {
                ContentUnavailableView(
                    "No bookmarks",
                    systemImage: "bookmark.slash",
                    description: Text("Long-press a recording and choose Bookmark this clip to save it for later.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleBookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                    .onDelete(perform: delete)
                }
            }
            if let exportStatus {
                Divider()
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .confirmationDialog(
            "Remove bookmark?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { bookmark in
            Button("Remove bookmark", role: .destructive) {
                Task { await performDelete(bookmark) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { bookmark in
            // Tell the user exactly what's getting removed —
            // including the downloaded clip if it's present — so
            // they can make an informed choice.
            if BookmarkAutoDownloader.hasLocalClip(for: bookmark) {
                Text("Removes the bookmark and the downloaded clip from this device. The original recording on the camera isn't affected.")
            } else {
                Text("Removes the bookmark. The original recording on the camera isn't affected.")
            }
        }
    }

    /// Centralized delete path. Both the explicit Delete button and
    /// the swipe-to-delete route here so the in-flight-download
    /// cancel + local-clip-file cleanup always runs.
    private func performDelete(_ bookmark: RecordingBookmark) async {
        await BookmarkAutoDownloader.shared.removeBookmark(bookmark)
        bookmarks = RecordingBookmarkStore.read(cameraID: cameraID)
        pendingDelete = nil
    }

    private func bookmarkRow(_ bookmark: RecordingBookmark) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.startDate, format: .dateTime.month().day().hour().minute())
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text(durationLabel(for: bookmark))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !bookmark.aiTagsAtMark.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(bookmark.aiTagsAtMark.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // 0.5.1 — show offline-ready state so the user can
                    // tell whether the bookmark's clip is on disk
                    // (background-downloaded) or will need to refetch.
                    if BookmarkAutoDownloader.hasLocalClip(for: bookmark) {
                        Text("·").foregroundStyle(.tertiary)
                        Label("Offline", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .font(.caption)
                            .accessibilityLabel("Downloaded — available offline")
                    }
                }
                if let note = bookmark.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if onExport != nil || transferable != nil {
                exportMenu(for: bookmark)
            }
            Button {
                onPlay(bookmark)
            } label: {
                Label("Play", systemImage: "play.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            // 0.6.0 — explicit Delete button, in addition to the
            // iOS swipe-to-delete. Discoverable on macOS (where
            // swipe is awkward) and on iPad Stage Manager (where a
            // pointer-driven user might not think to swipe).
            Button(role: .destructive) {
                pendingDelete = bookmark
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Remove this bookmark and its downloaded clip from this device.")
        }
        .padding(.vertical, 4)
        #if os(macOS)
        // 0.6.2 — Finder drag-out. The provider's file representation
        // runs `ClipExportCoordinator.stage` lazily, so the user just
        // grabs the row and drops it on Finder / Mail / Messages and
        // the system handles the trim + composition while showing its
        // own "Preparing…" indicator over the drag image.
        .onDrag {
            guard let transferable, let item = transferable(bookmark) else {
                return NSItemProvider()
            }
            let provider = NSItemProvider()
            provider.suggestedName = item.suggestedFilename + ".mp4"
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.mpeg4Movie.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                // NSItemProvider's loadHandler completion isn't
                // typed @Sendable in the SDK; wrap it in a thin
                // Sendable shim so the Task body can capture it
                // safely under Swift 6 strict concurrency.
                nonisolated(unsafe) let completion = completion
                Task {
                    do {
                        let staged = try await ClipExportCoordinator.stage(item.request)
                        completion(staged.stagedURL, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                // We don't surface granular progress — the system shows
                // its own indeterminate spinner while awaiting the
                // completion handler, which is the standard pattern.
                return nil
            }
            return provider
        }
        #endif
    }

    /// 0.6.2 — the per-row Export menu. Hosts the platform-appropriate
    /// destinations: iOS / iPadOS gets Save to Photos; macOS keeps the
    /// Save As… NSSavePanel route. Both platforms get Share… when the
    /// parent supplies a `transferable` closure that returns non-nil
    /// (typically gated on the bookmark having a fully-downloaded
    /// local clip). The macOS Finder drag-out destination lands in a
    /// subsequent 0.6.2 slice.
    @ViewBuilder
    private func exportMenu(for bookmark: RecordingBookmark) -> some View {
        Menu {
            if let onExport {
                #if os(iOS) || os(visionOS)
                Button {
                    onExport(bookmark, .photos)
                } label: {
                    Label("Save to Photos", systemImage: "photo.on.rectangle.angled")
                }
                #else
                Button {
                    onExport(bookmark, .savePanel)
                } label: {
                    Label("Save as MP4…", systemImage: "arrow.down.doc")
                }
                #endif
            }
            if let transferable, let item = transferable(bookmark) {
                ShareLink(item: item, preview: SharePreview(item.suggestedFilename)) {
                    Label("Share…", systemImage: "square.and.arrow.up.on.square")
                }
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        #if os(macOS)
        // Strip the default macOS Menu chrome (chevron + button bezel)
        // so the Export affordance aligns visually with the sibling
        // Play / Delete icon-only buttons in the row.
        .menuStyle(.borderlessButton)
        #endif
        .buttonStyle(.plain)
        .help("Export this bookmarked clip.")
        .accessibilityLabel("Export bookmarked clip")
    }

    private func durationLabel(for bookmark: RecordingBookmark) -> String {
        let secs = Int(bookmark.duration.rounded())
        let m = secs / 60
        let s = secs % 60
        return "\(m)m \(s)s"
    }

    private func delete(at offsets: IndexSet) {
        let snapshot = visibleBookmarks
        let targets = offsets.map { snapshot[$0] }
        Task {
            for target in targets {
                // 0.6.0 — route through the full-cleanup helper so
                // swipe-delete also cancels an in-flight download +
                // removes the downloaded clip file. Previously this
                // path only removed the JSON entry.
                await BookmarkAutoDownloader.shared.removeBookmark(target)
            }
            await MainActor.run {
                bookmarks = RecordingBookmarkStore.read(cameraID: cameraID)
            }
        }
    }
}

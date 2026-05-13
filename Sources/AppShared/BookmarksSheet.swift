import SwiftUI
import ReolinkAPI

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
    /// `RecordingsView.exportBookmark(_:)` which knows about the
    /// matching `SearchFile` and the camera's CGI client. Optional so
    /// the sheet can render in contexts (iOS, previews, tests)
    /// without an export pipeline.
    public let onExport: ((RecordingBookmark) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var exportStatus: String?

    public init(
        cameraID: UUID,
        cameraName: String,
        channel: Int? = nil,
        bookmarks: Binding<[RecordingBookmark]>,
        onPlay: @escaping (RecordingBookmark) -> Void,
        onExport: ((RecordingBookmark) -> Void)? = nil
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.channel = channel
        self._bookmarks = bookmarks
        self.onPlay = onPlay
        self.onExport = onExport
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
            if let onExport {
                Button {
                    onExport(bookmark)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Export this bookmarked clip to a MP4 file.")
            }
            Button {
                onPlay(bookmark)
            } label: {
                Label("Play", systemImage: "play.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func durationLabel(for bookmark: RecordingBookmark) -> String {
        let secs = Int(bookmark.duration.rounded())
        let m = secs / 60
        let s = secs % 60
        return "\(m)m \(s)s"
    }

    private func delete(at offsets: IndexSet) {
        let snapshot = visibleBookmarks
        for index in offsets {
            let target = snapshot[index]
            try? RecordingBookmarkStore.remove(id: target.id, cameraID: cameraID)
        }
        bookmarks = RecordingBookmarkStore.read(cameraID: cameraID)
    }
}

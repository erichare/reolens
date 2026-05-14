import SwiftUI
import ReolinkAPI

/// 0.6.0 Slice 13b — the three-row header stack that both iOS and
/// macOS RecordingsView shells render above the recordings list:
///
///   1. `MonthRecordingDensity` calendar density strip.
///   2. `DayTimelineStrip` (when there are visible files).
///   3. `AIEventFilterBar`.
///
/// The DatePicker stays on each platform shell because macOS has a
/// richer toolbar row (Raw-JSON popover, Bookmarks count badge,
/// Refresh button) that's all rendered at the same level as the
/// picker, and iOS uses the system navigation-bar drawer.
///
/// Each row is wrapped in `.reolensGlassToolbar()` to give the unified
/// "hovering chrome stripe" look.
public struct RecordingsScreenHeader: View {
    @Bindable public var loader: RecordingsLoader
    @Binding public var aiFilter: Set<DetectionType>
    public let filteredFiles: [SearchFile]
    public let onTapTimelineSegment: (SearchFile) -> Void

    public init(
        loader: RecordingsLoader,
        aiFilter: Binding<Set<DetectionType>>,
        filteredFiles: [SearchFile],
        onTapTimelineSegment: @escaping (SearchFile) -> Void
    ) {
        self.loader = loader
        self._aiFilter = aiFilter
        self.filteredFiles = filteredFiles
        self.onTapTimelineSegment = onTapTimelineSegment
    }

    public var body: some View {
        VStack(spacing: 0) {
            MonthRecordingDensity(
                selectedDate: $loader.selectedDate,
                monthStatuses: loader.monthStatuses
            )
            .reolensGlassToolbar()
            if !filteredFiles.isEmpty {
                DayTimelineStrip(
                    day: loader.selectedDate,
                    files: filteredFiles,
                    events: loader.dayEvents(),
                    onTapSegment: onTapTimelineSegment
                )
                .reolensGlassToolbar()
            }
            // 0.6.0 — hide the AI filter when there are no files at
            // all. The chip row is useless when there's nothing to
            // filter, and it was contributing ~46pt of "blank-feeling
            // header" above the empty-state message. Keep it visible
            // when files exist but the *filtered* subset is empty
            // so the user can clear the active filter back down.
            if !loader.files.isEmpty {
                AIEventFilterBar(selected: $aiFilter)
                    .reolensGlassToolbar()
            }
        }
    }
}

// MARK: - Auto-play helper

/// 0.6.0 Slice 13b — shared logic for the notification-tap auto-play
/// hint. Both iOS and macOS RecordingsView shells receive a
/// `scrollTarget: Date?` from the routing pipeline and need to play
/// the closest matching clip. Extracted so the algorithm only lives
/// in one place — the platform shells just pass in a `play` closure
/// that knows their platform's player wrapper.
public enum RecordingsAutoPlay {

    /// Return the file the auto-play hint should target, or nil if
    /// `target` falls outside the loaded day's data.
    ///
    /// Algorithm:
    /// 1. Containment first — if any file's `[start, end]` range
    ///    straddles `target`, that's the one the user wants.
    /// 2. Otherwise pick the file with the closest `startDate` to
    ///    `target`.
    public static func bestMatch(
        for target: Date,
        in candidates: [SearchFile]
    ) -> SearchFile? {
        if let containing = candidates.first(where: { file in
            guard let start = file.startDate, let end = file.endDate else { return false }
            return start <= target && target <= end
        }) {
            return containing
        }
        let withDistance = candidates.compactMap { file -> (SearchFile, TimeInterval)? in
            guard let start = file.startDate else { return nil }
            return (file, abs(start.timeIntervalSince(target)))
        }
        return withDistance.min(by: { $0.1 < $1.1 })?.0
    }
}

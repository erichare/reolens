import Foundation
import ReolinkAPI

/// Unified value type describing a recording the user wants to play.
///
/// Pre-rewrite the codebase had two incompatible `PlayableRecording`
/// shapes — one in `App/Views/RecordingPlayerSheet.swift` (macOS,
/// rich) and one in `AppiOS/Sources/Views/RecordingsView.swift` (iOS,
/// thin). Plus the cross-platform `AllRecordingsView` had its own ad-
/// hoc `PreviewTarget`. This type replaces all three so every
/// recording-playback entry point flows through one model.
///
/// The struct is content-stable: two recordings with the same `id`
/// represent the same clip even if their variants resolve at
/// different times (e.g. a token refresh re-signs the URL). This is
/// what makes `.sheet(item:)` reliable — SwiftUI uses `Identifiable`
/// to decide whether to rebuild the sheet on a swap.
///
/// Construction belongs to the entry-point views, which already hold
/// the camera session and credentials needed to sign the Reolink
/// `cmd=Download` URLs. The engine consumes the value type as read-
/// only: it never re-signs URLs or talks to a session.
public struct PlayableRecording: Identifiable, Hashable, Sendable {

    /// Stable identity. For per-camera recordings this is the source
    /// filename (`SearchFile.name`). For cross-camera rows (which can
    /// share filenames across channels) callers pass a namespaced ID
    /// like `"<channel>:<name>"`. SwiftUI uses this to gate `.sheet(
    /// item:)` rebuilds.
    public let id: String

    /// Human-readable title for the sheet header. Falls back to the
    /// filename if the camera doesn't have a display name.
    public let displayName: String

    /// Originating camera. Carried so the export router can pick a
    /// sensible suggested filename and so future deep-links (e.g.
    /// "Open Camera" from the player) know where to land.
    public let cameraID: UUID
    public let cameraName: String
    public let channel: Int

    /// Wall-clock recording window. Either bound can be nil on older
    /// firmware that omits the field.
    public let startDate: Date?
    public let endDate: Date?

    /// AI / motion detection tags surfaced in the header.
    public let detections: [DetectionType]

    /// Available quality variants. At least one is required; the
    /// initializer enforces it.
    public let highQuality: Variant?
    public let lowQuality: Variant?

    /// Which variant the sheet should start with. Engine still allows
    /// the user to flip mid-playback. Callers typically read
    /// `AppPreferences.defaultRecordingQuality` and fall through to
    /// `.low` if the chosen quality isn't available for this clip.
    public let initialQuality: RecordingQuality

    /// Optional trim — when set, exports limit the output to this
    /// range (seconds from the file's start). Playback itself isn't
    /// trimmed; the engine just keeps the value so the export router
    /// can honor it. Carries the bookmark-replay path.
    public let initialTrim: ClosedRange<TimeInterval>?

    /// A playable variant: where to fetch the bytes from, plus a
    /// progress hint. `url` may be `file://` (already-cached
    /// bookmark clip) or `https?://` (live Reolink CGI download URL,
    /// pre-signed with credentials or token).
    public struct Variant: Sendable, Hashable {
        public let url: URL
        public let file: SearchFile?
        /// Expected byte size if known. Reolink Search results carry
        /// this for files >0 bytes; bookmarks may not.
        public let expectedSize: Int64?

        public init(url: URL, file: SearchFile?, expectedSize: Int64? = nil) {
            self.url = url
            self.file = file
            // Prefer the explicit hint; fall back to the SearchFile.
            self.expectedSize = expectedSize
                ?? file?.size.map(Int64.init).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    public init(
        id: String,
        displayName: String,
        cameraID: UUID,
        cameraName: String,
        channel: Int,
        startDate: Date?,
        endDate: Date?,
        detections: [DetectionType] = [],
        highQuality: Variant?,
        lowQuality: Variant?,
        initialQuality: RecordingQuality,
        initialTrim: ClosedRange<TimeInterval>? = nil
    ) {
        precondition(
            highQuality != nil || lowQuality != nil,
            "PlayableRecording must carry at least one quality variant"
        )
        self.id = id
        self.displayName = displayName
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.channel = channel
        self.startDate = startDate
        self.endDate = endDate
        self.detections = detections
        self.highQuality = highQuality
        self.lowQuality = lowQuality
        // Honor the caller's preferred quality only if that variant
        // exists; otherwise fall through to whichever is available.
        let preferredAvailable = (initialQuality == .high && highQuality != nil)
            || (initialQuality == .low && lowQuality != nil)
        if preferredAvailable {
            self.initialQuality = initialQuality
        } else if highQuality != nil {
            self.initialQuality = .high
        } else {
            self.initialQuality = .low
        }
        self.initialTrim = initialTrim
    }

    // MARK: - Convenience

    /// The variant for `quality`, or nil if this recording doesn't
    /// have that variant available.
    public func variant(for quality: RecordingQuality) -> Variant? {
        switch quality {
        case .low: lowQuality
        case .high: highQuality
        }
    }

    /// Qualities the user can toggle between in the player. Order is
    /// stable (low, high) so the UI can render a segmented control
    /// consistently.
    public var availableQualities: [RecordingQuality] {
        var qs: [RecordingQuality] = []
        if lowQuality != nil { qs.append(.low) }
        if highQuality != nil { qs.append(.high) }
        return qs
    }

    /// `true` when the user can switch between low and high. False on
    /// camera/firmware combinations that only record one stream.
    public var canSwitchQuality: Bool { availableQualities.count > 1 }
}

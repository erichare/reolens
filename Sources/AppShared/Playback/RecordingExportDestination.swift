import Foundation

/// Where the user wants to send an explicitly-exported recording. The
/// router (`RecordingExportRouter`) translates each case into the
/// platform-native handoff:
///
///   * `.file`  → `UIDocumentPickerViewController(forExporting:)` on
///     iOS / iPadOS; `NSSavePanel` on macOS. A single "user picks a
///     location" surface, just spelled differently per OS.
///   * `.photos` → `PHAssetCreationRequest` via `ClipPhotosSaver`.
///     iOS / iPadOS / visionOS only — macOS Photos requires extra
///     entitlements we don't carry, and users who want a Mac copy use
///     `.file`.
///   * `.share` → SwiftUI `ShareLink` driven by a `Transferable` so
///     the system chrome owns the "Preparing…" UI. iOS only — macOS
///     drag-out from the bookmarks sheet already covers the same
///     workflow and we don't want to duplicate it inside the player.
public enum RecordingExportDestination: String, Sendable, CaseIterable, Hashable, Identifiable {
    case file
    case photos
    case share

    public var id: String { rawValue }

    /// The destinations available on the running platform. Used by the
    /// player sheet to render the Export menu. macOS exposes file +
    /// share; iOS exposes all three.
    public static var available: [RecordingExportDestination] {
        #if os(iOS) || os(visionOS)
        return [.file, .photos, .share]
        #elseif os(macOS)
        return [.file, .share]
        #else
        return [.file]
        #endif
    }

    public var label: String {
        switch self {
        case .file:
            #if os(macOS)
            return "Save As…"
            #else
            return "Save to Files"
            #endif
        case .photos: return "Save to Photos"
        case .share:  return "Share…"
        }
    }

    public var systemImage: String {
        switch self {
        case .file:   "arrow.down.doc"
        case .photos: "photo.on.rectangle.angled"
        case .share:  "square.and.arrow.up"
        }
    }
}

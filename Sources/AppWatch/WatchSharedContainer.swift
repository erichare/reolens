import Foundation

/// Mirror of the App Group container layout the iOS app publishes via
/// `AppShared.SharedContainer`. We re-declare a slim subset here rather
/// than depend on `AppShared` so the watch target compiles cleanly
/// without the iOS/macOS-leaning code that the full module pulls in
/// (SwiftUI scenes, AVFoundation playback, AppKit/UIKit shims).
///
/// **Contract:** the field layout below MUST match
/// `AppShared.SharedContainer.LatestSnapshot` and
/// `AppShared.SharedContainer.RecentMotionEvent` because we decode
/// the same binary plist files the iOS app writes. A drift in either
/// shape will cause silent decode failures on the watch (we treat
/// decode errors as "no data" — see `Reader.read*` below).
public enum WatchSharedContainer {

    /// App Group identifier — must match the iOS app's entitlement.
    /// Hard-coded rather than read from Info.plist because this is
    /// part of the shared contract with the iOS app, not a watch-
    /// specific configuration.
    public static let groupIdentifier = "group.com.reolens.Reolens"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    public static var snapshotsURL: URL? { containerURL?.appending(path: "LatestSnapshots.plist") }
    public static var eventsURL: URL? { containerURL?.appending(path: "RecentMotionEvents.plist") }
    public static var snapshotImagesDirectory: URL? { containerURL?.appending(path: "snapshots") }

    /// Slim mirror of `SharedContainer.LatestSnapshot`. The field
    /// names and ordering must match for plist decode to succeed.
    public struct LatestSnapshot: Codable, Sendable, Hashable, Identifiable {
        public let cameraID: UUID
        public let channel: Int
        public let cameraName: String
        public let lastUpdated: Date
        public let imageRelativePath: String?
        public let lastMotionAt: Date?

        /// Stable identity for SwiftUI lists — same camera with a
        /// new snapshot reuses the row rather than re-creating it.
        public var id: String { "\(cameraID.uuidString):\(channel)" }

        /// Absolute file URL for the snapshot JPEG, if present.
        public var imageURL: URL? {
            guard let rel = imageRelativePath,
                  let dir = WatchSharedContainer.snapshotImagesDirectory else { return nil }
            return dir.appending(path: rel)
        }
    }

    /// Slim mirror of `SharedContainer.RecentMotionEvent`.
    public struct RecentMotionEvent: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let cameraID: UUID
        public let channel: Int
        public let cameraName: String
        public let timestamp: Date
        public let aiTags: [String]
        public let triggerFrameRelativePath: String?
    }

    /// Read-side facade. All reads are best-effort: a missing file or
    /// a decode failure surfaces as an empty array so the UI degrades
    /// gracefully ("No cameras yet — open Reolens on your iPhone").
    public enum Reader {
        public static func readLatestSnapshots() -> [LatestSnapshot] {
            guard let url = snapshotsURL, let data = try? Data(contentsOf: url) else { return [] }
            return (try? PropertyListDecoder().decode([LatestSnapshot].self, from: data)) ?? []
        }

        public static func readRecentMotionEvents() -> [RecentMotionEvent] {
            guard let url = eventsURL, let data = try? Data(contentsOf: url) else { return [] }
            return (try? PropertyListDecoder().decode([RecentMotionEvent].self, from: data)) ?? []
        }

        /// Modification timestamp of the snapshots plist, used by the
        /// live view to detect "the iOS app refreshed our data" without
        /// re-decoding the whole file every poll tick.
        public static func snapshotsLastModified() -> Date? {
            guard let url = snapshotsURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return attrs[.modificationDate] as? Date
        }
    }
}

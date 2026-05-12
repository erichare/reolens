import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// `Transferable` payload that flows through SwiftUI's drag-and-drop for
/// reordering channel tiles within a device's grid.
///
/// We only need the integer channel ID — the rest is recoverable from
/// the session by looking the channel up by that ID. Lives in its own
/// file (rather than a view file) so the sidebar row and the grid tile
/// can both produce / accept it without duplicating the type.
///
/// Public so the iOS app target (a separate Xcode project consuming
/// AppShared as an SPM library product) can also wire `.draggable`/
/// `.dropDestination` for reorderable tiles.
public struct ChannelDragPayload: Codable, Transferable, Sendable {
    public let channel: Int

    public init(channel: Int) {
        self.channel = channel
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reolensChannelDrag)
    }
}

public extension UTType {
    /// Custom UTI registered just for our channel drag payloads — avoids
    /// the possibility of accidental drag-and-drop interop with other
    /// apps that publish plain `Int`s. Declared as an exported type in
    /// each app's `Info.plist`.
    static let reolensChannelDrag = UTType(exportedAs: "com.reolens.channelDrag")
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// `Transferable` payload that flows through SwiftUI's drag-and-drop.
/// We only need the integer channel ID — the rest is recoverable from
/// the session by looking the channel up by that ID. Lives in its own
/// file (rather than a view file) so the sidebar row and the grid tile
/// can both produce / accept it without duplicating the type.
package struct ChannelDragPayload: Codable, Transferable {
    package let channel: Int

    package init(channel: Int) {
        self.channel = channel
    }

    package static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reolensChannelDrag)
    }
}

package extension UTType {
    /// Custom UTI registered just for our drag payloads — avoids the
    /// possibility of accidental drag-and-drop interop with other apps
    /// that publish plain `Int`s. Declared as an exported type in the
    /// app's `Info.plist`.
    package static let reolensChannelDrag = UTType(exportedAs: "com.reolens.channelDrag")
}

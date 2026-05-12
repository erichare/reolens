import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// `Transferable` payload for reordering top-level devices in the sidebar
/// / device list. Mirrors `ChannelDragPayload` for the device-list
/// surface so the same drag-and-drop grammar works at both levels of the
/// hierarchy.
public struct DeviceDragPayload: Codable, Transferable, Sendable {
    public let deviceID: UUID

    public init(deviceID: UUID) {
        self.deviceID = deviceID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reolensDeviceDrag)
    }
}

public extension UTType {
    /// Custom UTI registered just for our device drag payloads. Declared
    /// as an exported type in each app's `Info.plist`. Namespaced under
    /// `com.reolens.*` so it can't be accidentally consumed by other apps.
    static let reolensDeviceDrag = UTType(exportedAs: "com.reolens.deviceDrag")
}

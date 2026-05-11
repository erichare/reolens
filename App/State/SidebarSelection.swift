import Foundation

/// What's currently highlighted in the sidebar.
///
/// - `.device`: a whole device — single cameras show their one feed, multi-channel
///   devices (NVRs, Home Hubs) show the grid of all channels.
/// - `.channel`: a specific channel under a device — always shows a single feed.
public enum SidebarSelection: Hashable, Sendable {
    case device(UUID)
    case channel(deviceID: UUID, channel: Int)

    public var deviceID: UUID {
        switch self {
        case .device(let id), .channel(let id, _): id
        }
    }

    public var channel: Int? {
        switch self {
        case .device: nil
        case .channel(_, let ch): ch
        }
    }
}

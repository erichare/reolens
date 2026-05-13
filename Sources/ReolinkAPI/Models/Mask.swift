import Foundation

/// 0.5.0 Theme C2 — Reolink CGI `Mask` (privacy mask) wire types.
///
/// Reolink exposes per-channel privacy masks via `GetMask` / `SetMask`.
/// Each mask is a small set of rectangle areas (up to 4 on most
/// firmware) given in normalized 0…1 image-space coordinates with
/// origin at the top-left corner.
///
/// The shape was reverse-engineered from observation against a Home
/// Hub Pro running v3.3.0. Newer firmware accepts the same envelope.
/// Older firmware (< v2.0.0) may not implement `SetMask` and will
/// respond with rspCode = -9 (not supported); the caller surfaces
/// that to the user.
public struct MaskSettings: Codable, Sendable, Hashable {
    public let channel: Int
    public var enable: Int
    public var area: [MaskArea]

    public init(channel: Int, enable: Int, area: [MaskArea]) {
        self.channel = channel
        self.enable = enable
        self.area = area
    }
}

public struct MaskArea: Codable, Sendable, Hashable {
    /// Origin x, normalized 0…1, top-left corner.
    public let x: Double
    /// Origin y, normalized 0…1, top-left corner.
    public let y: Double
    /// Width, normalized 0…1.
    public let w: Double
    /// Height, normalized 0…1.
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct MaskEnvelope: Codable, Sendable {
    public let Mask: MaskSettings
}

public struct SetMaskParam: Encodable, Sendable {
    public let Mask: MaskSettings
}

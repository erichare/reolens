import Foundation

/// Per-channel motion-detection privacy zones (Theme C2). Reolink
/// firmware accepts up to 4 rectangles per channel; each is the
/// normalized bounding box in the camera's coordinate space.
///
/// Normalized coordinates (`x`, `y`, `width`, `height` ∈ [0, 1]) so
/// the same zone description applies regardless of stream resolution
/// — the editor renders against whichever snapshot is currently
/// visible. AGENTS.md §1 (parity): identical model and persistence
/// on macOS and iOS.
public struct PrivacyZone: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        id: UUID = UUID(),
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.x = max(0, min(1, x))
        self.y = max(0, min(1, y))
        self.width = max(0, min(1, width))
        self.height = max(0, min(1, height))
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Live working set of zones. Validation enforces the hard 4-zone
/// camera-side cap and clamps each rect into the unit square.
public struct PrivacyZoneEditorModel: Sendable, Hashable {

    public static let maxZones = 4

    public var zones: [PrivacyZone]

    public init(zones: [PrivacyZone] = []) {
        self.zones = Array(zones.prefix(Self.maxZones))
    }

    public mutating func add(_ zone: PrivacyZone) {
        guard zones.count < Self.maxZones else { return }
        guard !zone.isEmpty else { return }
        zones.append(zone)
    }

    public mutating func remove(id: UUID) {
        zones.removeAll { $0.id == id }
    }

    public mutating func update(id: UUID, transform: (inout PrivacyZone) -> Void) {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        transform(&zones[index])
        if zones[index].isEmpty {
            zones.remove(at: index)
        }
    }
}

/// Platform-agnostic gesture math for drawing/resizing a rectangle
/// inside a 1×1 unit square. Pulled out of the SwiftUI layer so the
/// same logic is used on macOS pointer + iOS touch surfaces.
/// AGENTS.md §6 (no duplication between platforms).
public enum RectEditor {

    /// Build a rectangle from two corner points (drag start, drag
    /// end). Normalizes to "positive" width / height so the order of
    /// the corners doesn't matter.
    public static func rectangleFromCorners(
        start: (x: Double, y: Double),
        end: (x: Double, y: Double)
    ) -> PrivacyZone {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)
        return PrivacyZone(x: x, y: y, width: w, height: h)
    }

    /// Move an existing rectangle by `(dx, dy)`, clamping so it
    /// stays inside the unit square.
    public static func translate(_ zone: PrivacyZone, dx: Double, dy: Double) -> PrivacyZone {
        let newX = max(0, min(1 - zone.width, zone.x + dx))
        let newY = max(0, min(1 - zone.height, zone.y + dy))
        return PrivacyZone(id: zone.id, x: newX, y: newY, width: zone.width, height: zone.height)
    }
}

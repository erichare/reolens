import Foundation

/// Layout preset for the multi-camera grid. Each preset is a (columns,
/// optional minimum-tile-width) tuple — `.adaptive` lets SwiftUI's
/// `GridItem(.adaptive(...))` fit as many tiles as the available width
/// allows, while the numbered presets force a fixed column count for a
/// consistent N-up view.
public enum GridPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case adaptive
    case spotlight
    case single
    case twoByTwo
    case threeByThree
    case fourByFour
    case fiveByFive

    public var id: String { rawValue }

    /// Number of columns in the fixed-grid case. `nil` means "let SwiftUI
    /// decide" (adaptive) or "the grid uses a custom layout" (spotlight).
    public var columns: Int? {
        switch self {
        case .adaptive, .spotlight: nil
        case .single: 1
        case .twoByTwo: 2
        case .threeByThree: 3
        case .fourByFour: 4
        case .fiveByFive: 5
        }
    }

    /// Approximate "rows of tiles visible at a time" — used to size each
    /// tile so the chosen number of tiles fills the visible area. With
    /// `.single` we let one tile take all the height; with `.adaptive` we
    /// fall back to per-tile min/max heights set by the caller.
    public var rowsOnScreen: Int? {
        switch self {
        case .adaptive, .spotlight: nil
        case .single: 1
        case .twoByTwo: 2
        case .threeByThree: 3
        case .fourByFour: 4
        case .fiveByFive: 5
        }
    }

    public var label: String {
        switch self {
        case .adaptive: "Adaptive"
        case .spotlight: "Spotlight"
        case .single: "Single"
        case .twoByTwo: "2 × 2"
        case .threeByThree: "3 × 3"
        case .fourByFour: "4 × 4"
        case .fiveByFive: "5 × 5"
        }
    }

    public var systemImage: String {
        switch self {
        case .adaptive: "square.grid.3x3"
        case .spotlight: "rectangle.inset.topleading.filled"
        case .single: "rectangle"
        case .twoByTwo: "square.grid.2x2"
        case .threeByThree: "square.grid.3x3"
        case .fourByFour: "square.grid.4x3.fill"
        case .fiveByFive: "square.grid.3x3.square"
        }
    }
}

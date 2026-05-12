import SwiftUI

/// "Jiggle" animation modifier — applies the small autoreversing rotation
/// that iOS uses on the home screen when icons are in edit mode. Shared
/// between macOS, iPadOS, and iPhone so the reorder UX feels identical
/// across platforms.
///
/// Each instance picks a randomized phase offset and amplitude within a
/// narrow band so neighboring tiles don't oscillate in lockstep — this
/// is what gives the home-screen effect its organic feel.
///
/// Respects `@Environment(\.accessibilityReduceMotion)`: when the user
/// has Reduce Motion on, the rotation is suppressed and a static dashed
/// outline is shown in its place to still communicate "reorderable".
public struct JiggleModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let isActive: Bool

    /// Phase and amplitude state — randomized per-instance once, on
    /// first appear, so each tile gets its own slightly different feel
    /// without resetting on every state change.
    @State private var phase: Double = .random(in: 0...(.pi * 2))
    @State private var amplitude: Double = .random(in: 1.4...2.2)
    @State private var period: Double = .random(in: 0.16...0.22)

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if isActive {
            if reduceMotion {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.tint.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    )
            } else {
                content
                    .rotationEffect(.degrees(amplitude * sin(phase)))
                    .animation(
                        .easeInOut(duration: period).repeatForever(autoreverses: true),
                        value: phase
                    )
                    .onAppear { phase = -phase }
            }
        } else {
            content
        }
    }
}

public extension View {
    /// Apply the iOS-home-screen jiggle effect when `isActive` is true.
    /// Honors Reduce Motion (replaces motion with a dashed outline).
    func jiggle(isActive: Bool) -> some View {
        modifier(JiggleModifier(isActive: isActive))
    }
}

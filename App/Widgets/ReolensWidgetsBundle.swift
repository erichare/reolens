import WidgetKit
import SwiftUI

/// 0.5.0 Theme A1 (macOS twin) — desktop widget bundle. Hosts the
/// same three widget kinds as iOS, minus the iOS-only Live Activity
/// and Control Center widgets (AGENTS.md §1 — Live Activities are an
/// explicit iOS-only carve-out; Control widgets are iOS 18+ Home
/// Screen-grid affordances without a macOS analog).
///
/// macOS 26 supports `.systemSmall`, `.systemMedium`, `.systemLarge`,
/// and `.systemExtraLarge` on the desktop. The Reolens widgets
/// declare the same families as their iOS twins for consistency;
/// `extraLarge` is intentionally omitted to keep the rendering code
/// shared (extraLarge isn't broadly useful for a video-thumbnail
/// widget without a denser layout that the small/medium/large tiers
/// already cover).
@main
struct ReolensWidgetsBundle: WidgetBundle {

    var body: some Widget {
        CameraSnapshotWidget()
        LastMotionWidget()
        MotionDigestWidget()
    }
}

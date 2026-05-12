import SwiftUI
import ReolinkAPI
import AppShared

/// Touch-adapted PTZ control. Larger hit targets than the macOS
/// counterpart (44pt minimum per Apple HIG), grouped into a 3×3
/// directional pad plus separate Zoom and Focus rows below.
///
/// Press-and-hold streams motion to the camera continuously; release
/// sends a `.stop` so the camera doesn't keep panning after the user
/// lifts their finger. Implemented with `DragGesture(minimumDistance:
/// 0)` exactly like the macOS app — the gesture behaves identically
/// on touch.
struct PTZControlView: View {
    let session: CameraSession
    let channelID: Int

    private static let cellSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 14) {
            DirectionalPad(
                onPress: { op in Task { await session.ptz(channel: channelID, op: op) } },
                onRelease: { Task { await session.ptz(channel: channelID, op: .stop) } }
            )

            HStack(spacing: 20) {
                ptzGroup(label: "Zoom",
                         minus: ("minus.magnifyingglass", .zoomOut),
                         plus: ("plus.magnifyingglass", .zoomIn))
                ptzGroup(label: "Focus",
                         minus: ("minus", .focusOut),
                         plus: ("plus", .focusIn))
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    private func ptzGroup(label: String,
                          minus: (icon: String, op: PtzOp),
                          plus: (icon: String, op: PtzOp)) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                pressCell(systemImage: minus.icon, op: minus.op)
                pressCell(systemImage: plus.icon, op: plus.op)
            }
        }
    }

    private func pressCell(systemImage: String, op: PtzOp) -> some View {
        Image(systemName: systemImage)
            .font(.title3)
            .frame(width: Self.cellSize, height: Self.cellSize)
            .contentShape(.rect)
            .background(.quaternary, in: .rect(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        Task { await session.ptz(channel: channelID, op: op) }
                    }
                    .onEnded { _ in
                        Task { await session.ptz(channel: channelID, op: .stop) }
                    }
            )
    }
}

private struct DirectionalPad: View {
    let onPress: (PtzOp) -> Void
    let onRelease: () -> Void
    private static let cellSize: CGFloat = 60

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                padCell("arrow.up.left", op: .leftUp)
                padCell("arrow.up", op: .up)
                padCell("arrow.up.right", op: .rightUp)
            }
            GridRow {
                padCell("arrow.left", op: .left)
                Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                padCell("arrow.right", op: .right)
            }
            GridRow {
                padCell("arrow.down.left", op: .leftDown)
                padCell("arrow.down", op: .down)
                padCell("arrow.down.right", op: .rightDown)
            }
        }
    }

    private func padCell(_ systemImage: String, op: PtzOp) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: Self.cellSize, height: Self.cellSize)
            .contentShape(.rect)
            .background(.quaternary, in: .rect(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress(op) }
                    .onEnded { _ in onRelease() }
            )
    }
}

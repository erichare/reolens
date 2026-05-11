import SwiftUI
import ReolinkAPI

struct PTZControlBar: View {
    let session: CameraSession
    let channel: Int

    var body: some View {
        HStack(spacing: 16) {
            DirectionalPad { op in
                Task { await session.ptz(channel: channel, op: op) }
            } onRelease: {
                Task { await session.ptz(channel: channel, op: .stop) }
            }

            VStack(spacing: 6) {
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                HStack {
                    pressButton(systemImage: "minus.magnifyingglass", op: .zoomOut)
                    pressButton(systemImage: "plus.magnifyingglass", op: .zoomIn)
                }
            }
            VStack(spacing: 6) {
                Text("Focus").font(.caption).foregroundStyle(.secondary)
                HStack {
                    pressButton(systemImage: "minus", op: .focusOut)
                    pressButton(systemImage: "plus", op: .focusIn)
                }
            }
            Spacer()
        }
    }

    private func pressButton(systemImage: String, op: PtzOp) -> some View {
        Image(systemName: systemImage)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        Task { await session.ptz(channel: channel, op: op) }
                    }
                    .onEnded { _ in
                        Task { await session.ptz(channel: channel, op: .stop) }
                    }
            )
    }
}

struct DirectionalPad: View {
    let onPress: (PtzOp) -> Void
    let onRelease: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                padCell(systemImage: "arrow.up.left", op: .leftUp)
                padCell(systemImage: "arrow.up", op: .up)
                padCell(systemImage: "arrow.up.right", op: .rightUp)
            }
            GridRow {
                padCell(systemImage: "arrow.left", op: .left)
                Color.clear.frame(width: 32, height: 32)
                padCell(systemImage: "arrow.right", op: .right)
            }
            GridRow {
                padCell(systemImage: "arrow.down.left", op: .leftDown)
                padCell(systemImage: "arrow.down", op: .down)
                padCell(systemImage: "arrow.down.right", op: .rightDown)
            }
        }
    }

    private func padCell(systemImage: String, op: PtzOp) -> some View {
        Image(systemName: systemImage)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress(op) }
                    .onEnded { _ in onRelease() }
            )
    }
}

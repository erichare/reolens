import SwiftUI
import ReolinkAPI
import AppShared

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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Zoom controls")
            VStack(spacing: 6) {
                Text("Focus").font(.caption).foregroundStyle(.secondary)
                HStack {
                    pressButton(systemImage: "minus", op: .focusOut)
                    pressButton(systemImage: "plus", op: .focusIn)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Focus controls")
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
            .accessibilityLabel(PTZAccessibility.label(for: op))
            .accessibilityHint("Press and hold to apply.")
            .accessibilityAddTraits(.isButton)
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
                    .accessibilityHidden(true)
                padCell(systemImage: "arrow.right", op: .right)
            }
            GridRow {
                padCell(systemImage: "arrow.down.left", op: .leftDown)
                padCell(systemImage: "arrow.down", op: .down)
                padCell(systemImage: "arrow.down.right", op: .rightDown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pan and tilt directional pad")
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
            .accessibilityLabel(PTZAccessibility.label(for: op))
            .accessibilityHint("Press and hold to pan.")
            .accessibilityAddTraits(.isButton)
    }
}

/// 0.6.1 — Centralized VoiceOver labels for `PtzOp` so the PTZ bar
/// and any future surfaces stay in lockstep. Keep these short and
/// imperative — VoiceOver announces them on focus, so a tactile-sounding
/// label ("pan up", "zoom in") beats a long sentence.
enum PTZAccessibility {
    static func label(for op: PtzOp) -> String {
        switch op {
        case .up: return "Pan up"
        case .down: return "Pan down"
        case .left: return "Pan left"
        case .right: return "Pan right"
        case .leftUp: return "Pan up and left"
        case .rightUp: return "Pan up and right"
        case .leftDown: return "Pan down and left"
        case .rightDown: return "Pan down and right"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .focusIn: return "Focus near"
        case .focusOut: return "Focus far"
        case .stop: return "Stop"
        default: return "PTZ control"
        }
    }
}

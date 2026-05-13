import SwiftUI

/// 0.5.0 Theme C2 — visual rectangle editor for the up-to-4 motion
/// privacy zones the Reolink firmware accepts per channel. Drag on
/// empty space to draw a new zone; drag inside a zone to move it;
/// long-press to delete. Each zone is the normalized (0…1) bounding
/// box in the camera's coordinate space, so the same description
/// applies regardless of stream resolution.
///
/// Platform parity: identical view on macOS and iOS. The drag
/// gestures use SwiftUI's cross-platform `DragGesture`. AGENTS.md §1.
public struct PrivacyZoneEditorView: View {

    @Binding public var model: PrivacyZoneEditorModel
    /// Optional background image (a recent snapshot of the camera).
    /// The editor renders over it so the user can see what their
    /// rectangles mask. Pass `nil` for a checker-board placeholder.
    public let backgroundImage: PrivacyZoneBackgroundImage?

    public init(
        model: Binding<PrivacyZoneEditorModel>,
        backgroundImage: PrivacyZoneBackgroundImage?
    ) {
        self._model = model
        self.backgroundImage = backgroundImage
    }

    @State private var drawStart: CGPoint?
    @State private var drawEnd: CGPoint?
    @State private var dragOffsets: [UUID: CGSize] = [:]

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                backgroundLayer(proxy: proxy)
                zoneOverlay(proxy: proxy)
                drawPreview(proxy: proxy)
                if model.zones.count >= PrivacyZoneEditorModel.maxZones {
                    Text("Maximum \(PrivacyZoneEditorModel.maxZones) zones")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: .capsule)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .contentShape(.rect)
            .gesture(drawGesture(proxy: proxy))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        }
        // 0.5.0 Liquid Glass — the rectangle-drawing surface reads as
        // a glass card lifted above the surrounding Form so the user
        // sees it as the focal point of the section.
        .reolensGlassCard()
        .accessibilityLabel("Motion privacy zone editor")
    }

    @ViewBuilder
    private func backgroundLayer(proxy: GeometryProxy) -> some View {
        if let backgroundImage {
            backgroundImage.swiftUIImage
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        } else {
            // Subtle checker pattern so the user sees the editing
            // area even with no snapshot.
            Canvas { context, size in
                let cell: CGFloat = 12
                for row in 0..<Int((size.height / cell).rounded(.up)) {
                    for col in 0..<Int((size.width / cell).rounded(.up)) {
                        if (row + col).isMultiple(of: 2) {
                            let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                            context.fill(Path(rect), with: .color(.secondary.opacity(0.15)))
                        }
                    }
                }
            }
        }
    }

    private func zoneOverlay(proxy: GeometryProxy) -> some View {
        ForEach(model.zones) { zone in
            let frame = frameForZone(zone, in: proxy.size, dragOffset: dragOffsets[zone.id] ?? .zero)
            RoundedRectangle(cornerRadius: 6)
                .fill(.red.opacity(0.20))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.red, lineWidth: 1.5)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        model.remove(id: zone.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(moveGesture(zone: zone, in: proxy.size))
        }
    }

    @ViewBuilder
    private func drawPreview(proxy: GeometryProxy) -> some View {
        if let start = drawStart, let end = drawEnd {
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            RoundedRectangle(cornerRadius: 6)
                .stroke(.red, style: .init(lineWidth: 1.5, dash: [4, 4]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func drawGesture(proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard model.zones.count < PrivacyZoneEditorModel.maxZones else { return }
                if drawStart == nil {
                    drawStart = value.startLocation
                }
                drawEnd = value.location
            }
            .onEnded { value in
                defer {
                    drawStart = nil
                    drawEnd = nil
                }
                guard let start = drawStart else { return }
                let end = value.location
                let zone = RectEditor.rectangleFromCorners(
                    start: (Double(start.x / proxy.size.width), Double(start.y / proxy.size.height)),
                    end: (Double(end.x / proxy.size.width), Double(end.y / proxy.size.height))
                )
                model.add(zone)
            }
    }

    private func moveGesture(zone: PrivacyZone, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                dragOffsets[zone.id] = value.translation
            }
            .onEnded { value in
                dragOffsets[zone.id] = nil
                let dx = Double(value.translation.width / size.width)
                let dy = Double(value.translation.height / size.height)
                model.update(id: zone.id) { current in
                    current = RectEditor.translate(current, dx: dx, dy: dy)
                }
            }
    }

    private func frameForZone(_ zone: PrivacyZone, in size: CGSize, dragOffset: CGSize) -> CGRect {
        CGRect(
            x: zone.x * size.width + dragOffset.width,
            y: zone.y * size.height + dragOffset.height,
            width: zone.width * size.width,
            height: zone.height * size.height
        )
    }
}

#if canImport(AppKit)
import AppKit
public struct PrivacyZoneBackgroundImage: Sendable {
    public let nsImage: NSImage
    public init(nsImage: NSImage) { self.nsImage = nsImage }
    public var swiftUIImage: Image { Image(nsImage: nsImage) }
}
#elseif canImport(UIKit)
import UIKit
public struct PrivacyZoneBackgroundImage: Sendable {
    public let uiImage: UIImage
    public init(uiImage: UIImage) { self.uiImage = uiImage }
    public var swiftUIImage: Image { Image(uiImage: uiImage) }
}
#endif

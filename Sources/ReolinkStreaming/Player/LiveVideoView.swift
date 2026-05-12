import SwiftUI
import AVFoundation
import OSLog

#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.streaming", category: "view")

/// SwiftUI wrapper that hosts an `AVSampleBufferDisplayLayer` for a `LiveVideoPlayer`.
///
/// `rotationDegrees` is passed as a separate, SwiftUI-tracked parameter rather
/// than read from the player. SwiftUI's update callback doesn't observe
/// `@Observable` properties of an embedded reference type reliably, so passing
/// rotation as a struct parameter ensures changes propagate to the host view.
#if os(macOS)
public struct LiveVideoView: NSViewRepresentable {
    private let player: LiveVideoPlayer
    private let rotationDegrees: Int

    public init(player: LiveVideoPlayer, rotationDegrees: Int = 0) {
        self.player = player
        self.rotationDegrees = rotationDegrees
    }

    public func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
        // Register the host view with the player so snapshot capture
        // can route through the display-cache pipeline. Weak ref on
        // the player side, so the view is free to deinit normally.
        player.snapshotHost = view
        return view
    }

    public func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        nsView.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
        // updateNSView fires on every SwiftUI render; re-binding here
        // is idempotent and keeps the player's host pointer aligned
        // with the view actually on screen if SwiftUI ever swaps it.
        player.snapshotHost = nsView
    }
}
#else
public struct LiveVideoView: UIViewRepresentable {
    private let player: LiveVideoPlayer
    private let rotationDegrees: Int

    public init(player: LiveVideoPlayer, rotationDegrees: Int = 0) {
        self.player = player
        self.rotationDegrees = rotationDegrees
    }

    public func makeUIView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
        // Register the host view with the player so snapshot capture
        // can route through the display-cache pipeline. Weak ref on
        // the player side, so the view is free to deinit normally.
        player.snapshotHost = view
        return view
    }

    public func updateUIView(_ uiView: SampleBufferHostView, context: Context) {
        uiView.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
        player.snapshotHost = uiView
    }
}
#endif

#if os(macOS)
public final class SampleBufferHostView: NSView {
    private var hosted: AVSampleBufferDisplayLayer?
    private var rotationDegrees: Int = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public func attach(layer: AVSampleBufferDisplayLayer, rotationDegrees: Int) {
        let layerChanged = hosted !== layer
        let rotationChanged = self.rotationDegrees != rotationDegrees
        self.rotationDegrees = rotationDegrees
        if layerChanged {
            hosted?.removeFromSuperlayer()
            layer.contentsScale = window?.backingScaleFactor ?? 2
            self.layer?.addSublayer(layer)
            self.hosted = layer
        }
        if layerChanged || rotationChanged {
            needsLayout = true
        }
    }

    public override func layout() {
        super.layout()
        applyLayout()
    }

    public override var isFlipped: Bool { true }

    private func applyLayout() {
        guard let hosted else { return }
        let isSideways = (rotationDegrees % 180) != 0
        if isSideways {
            hosted.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
        } else {
            hosted.bounds = CGRect(origin: .zero, size: bounds.size)
        }
        hosted.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let radians = CGFloat(rotationDegrees) * .pi / 180
        hosted.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        log.debug("layout host=\(NSStringFromRect(self.bounds), privacy: .public) layer.bounds=\(NSStringFromRect(hosted.bounds), privacy: .public) rotation=\(self.rotationDegrees) hidden=\(hosted.isHidden) inWindow=\(self.window != nil)")
    }
}
#else
public final class SampleBufferHostView: UIView {
    private var hosted: AVSampleBufferDisplayLayer?
    private var rotationDegrees: Int = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    public func attach(layer: AVSampleBufferDisplayLayer, rotationDegrees: Int) {
        let layerChanged = hosted !== layer
        let rotationChanged = self.rotationDegrees != rotationDegrees
        self.rotationDegrees = rotationDegrees
        if layerChanged {
            hosted?.removeFromSuperlayer()
            layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            self.layer.addSublayer(layer)
            self.hosted = layer
        }
        if layerChanged || rotationChanged {
            setNeedsLayout()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let hosted else { return }
        let isSideways = (rotationDegrees % 180) != 0
        if isSideways {
            hosted.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
        } else {
            hosted.bounds = CGRect(origin: .zero, size: bounds.size)
        }
        hosted.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let radians = CGFloat(rotationDegrees) * .pi / 180
        hosted.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        log.debug("layout host=\(NSCoder.string(for: self.bounds), privacy: .public) layer.bounds=\(NSCoder.string(for: hosted.bounds), privacy: .public) rotation=\(self.rotationDegrees) hidden=\(hosted.isHidden) inWindow=\(self.window != nil)")
    }
}
#endif

// MARK: - Snapshot

#if os(macOS)
extension SampleBufferHostView: SnapshotCapable {
    /// Capture the currently-rendered video frame via AppKit's
    /// display-cache pipeline. Returns nil if the view isn't laid
    /// out or isn't in a window — both happen briefly during the
    /// SwiftUI mount sequence, and the snapshot UI surfaces a
    /// friendly "still connecting" message in those cases.
    public func captureSnapshot() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }
}
#else
extension SampleBufferHostView: SnapshotCapable {
    /// Capture the currently-rendered video frame via UIKit's
    /// drawHierarchy pipeline. Unlike `CALayer.render(in:)`, this
    /// goes through the same render path the screen uses, which is
    /// the only way to extract a frame from an
    /// `AVSampleBufferDisplayLayer` — the layer doesn't expose its
    /// decoded contents through the public CoreAnimation API.
    public func captureSnapshot() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // afterScreenUpdates: false because we want the frame as it
        // currently appears on screen — true would force a synchronous
        // re-render of the whole hierarchy, which both costs more CPU
        // and can stall mid-decode pipelines.
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return image.cgImage
    }
}
#endif

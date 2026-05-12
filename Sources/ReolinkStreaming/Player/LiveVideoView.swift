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
        return view
    }

    public func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        nsView.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
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
        return view
    }

    public func updateUIView(_ uiView: SampleBufferHostView, context: Context) {
        uiView.attach(layer: player.displayLayer, rotationDegrees: rotationDegrees)
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


#!/usr/bin/env swift
// Generate placeholder screenshots so the landing page and README render
// cleanly before real captures are taken. Each placeholder is a labeled
// 16:10 PNG that matches the page layout.
//
// Replace by running the app, screen-capturing the relevant view, blurring
// any visible camera footage with Scripts/blur-screenshot.sh, and dropping
// the result at the same filename under docs/screenshots/.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

let outputs: [(name: String, label: String)] = [
    ("grid-adaptive.png", "Adaptive grid"),
    ("spotlight.png",     "Spotlight layout"),
    ("detail-ptz.png",    "Detail + PTZ"),
    ("notification.png",  "Rich alarm notification"),
]

let W: CGFloat = 1600
let H: CGFloat = 1000

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot.appendingPathComponent("docs/screenshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func drawText(_ ctx: CGContext, _ string: String, fontSize: CGFloat, weight: CGFloat, at point: CGPoint, alpha: CGFloat = 1) {
    let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
    let attrs: [CFString: Any] = [
        kCTFontTraitsAttribute: traits,
        kCTFontFamilyNameAttribute: "Helvetica Neue",
    ]
    let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
    let lineAttrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color(1, 1, 1, alpha),
    ]
    let attr = CFAttributedStringCreate(nil, string as CFString, lineAttrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

for (name, label) in outputs {
    guard let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
        bytesPerRow: Int(W) * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    // Backdrop gradient.
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0.10, 0.20, 0.36), color(0.05, 0.08, 0.16)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: W / 2, y: H), end: CGPoint(x: W / 2, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Faux window chrome — a single rounded inner frame.
    ctx.saveGState()
    let pad: CGFloat = 60
    let frame = CGRect(x: pad, y: pad, width: W - pad * 2, height: H - pad * 2)
    let path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(color(1, 1, 1, 0.06))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    // Three traffic-light circles (top-left).
    let circleY = H - 96
    for (i, c) in [color(0.92, 0.34, 0.32), color(0.95, 0.74, 0.22), color(0.32, 0.78, 0.34)].enumerated() {
        ctx.saveGState()
        ctx.setFillColor(c)
        ctx.addArc(center: CGPoint(x: 100 + CGFloat(i) * 28, y: circleY), radius: 8, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Label.
    drawText(ctx, label, fontSize: 44, weight: 0.4, at: CGPoint(x: pad + 64, y: H / 2 + 12))
    drawText(ctx, "Screenshot coming soon", fontSize: 22, weight: 0, at: CGPoint(x: pad + 64, y: H / 2 - 30), alpha: 0.55)

    // Write PNG.
    guard let image = ctx.makeImage() else { continue }
    let url = outDir.appendingPathComponent(name) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \((url as URL).path)")
}

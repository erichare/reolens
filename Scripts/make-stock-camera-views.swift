#!/usr/bin/env swift
// Generate a small library of stylized "camera view" PNGs that stand in
// for real footage in marketing screenshots. The goal is a clean,
// privacy-respecting alternative to publishing blurred captures: each
// PNG looks plausibly like a security-camera still (porch, driveway,
// backyard, garage, side gate, package porch), but is 100% procedural
// CoreGraphics — no stock-photo licensing, no AI-generation tooling
// required to build.
//
// Output: docs/assets/stock-cameras/{slug}.png at 1280×720 (16:9).
//
// To use in screenshots:
//   1. Run this script. PNGs land in docs/assets/stock-cameras/.
//   2. Either capture a fresh raw screenshot of the app and run
//      Scripts/composite-screenshot.sh to overlay these into the tile
//      regions, or let make-placeholder-screenshots.swift build a
//      ready-to-publish placeholder that already embeds them.
//
// Style: flat layered illustration with soft gradients and a faint
// security-camera tint (slight cool cast + bottom-right timestamp).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

let W: CGFloat = 1280
let H: CGFloat = 720

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot.appendingPathComponent("docs/assets/stock-cameras")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()

// MARK: - Helpers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func newContext() -> CGContext {
    CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
        bytesPerRow: Int(W) * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// Draw a linear gradient, optionally clipped to a rect so it doesn't
/// bleed into other scene layers. The default (no clip) confines the
/// gradient to the band between `from` and `to` — passing
/// `extendEnds: true` matches the old "drawsBeforeStartLocation +
/// drawsAfterEndLocation" behavior for full-canvas backdrops.
func fillGradient(
    _ ctx: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    from: CGPoint,
    to: CGPoint,
    clipTo clipRect: CGRect? = nil,
    extendEnds: Bool = false
) {
    let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    let opts: CGGradientDrawingOptions = extendEnds
        ? [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        : []
    ctx.saveGState()
    if let clipRect {
        ctx.clip(to: clipRect)
    }
    ctx.drawLinearGradient(grad, start: from, end: to, options: opts)
    ctx.restoreGState()
}

func rect(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.fill(r)
}

func roundedRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, _ c: CGColor) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(c)
    ctx.fillPath()
}

func drawText(_ ctx: CGContext, _ string: String, fontSize: CGFloat, weight: CGFloat = 0, at point: CGPoint, color textColor: CGColor) {
    let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
    let attrs: [CFString: Any] = [
        kCTFontTraitsAttribute: traits,
        kCTFontFamilyNameAttribute: "Helvetica Neue",
    ]
    let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
    let lineAttrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: textColor,
    ]
    let attr = CFAttributedStringCreate(nil, string as CFString, lineAttrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

/// Common chrome applied to every camera scene: subtle vignette, a tiny
/// "REC" dot, and a timestamp in the bottom-right corner. Makes the
/// images read as "security camera capture" at a glance.
func applyCameraChrome(_ ctx: CGContext, timestamp: String, label: String) {
    // Vignette.
    let vignette = CGGradient(
        colorsSpace: space,
        colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.55)] as CFArray,
        locations: [0.55, 1]
    )!
    ctx.drawRadialGradient(
        vignette,
        startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
        endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: max(W, H) * 0.7,
        options: []
    )

    // REC dot + label top-left.
    ctx.setFillColor(color(0.96, 0.22, 0.20))
    ctx.addArc(center: CGPoint(x: 36, y: H - 36), radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    drawText(ctx, "REC", fontSize: 18, weight: 0.4, at: CGPoint(x: 54, y: H - 44), color: color(1, 1, 1, 0.9))
    drawText(ctx, label.uppercased(), fontSize: 14, weight: 0.2, at: CGPoint(x: 54, y: H - 64), color: color(1, 1, 1, 0.65))

    // Timestamp bottom-right.
    drawText(ctx, timestamp, fontSize: 18, weight: 0.4, at: CGPoint(x: W - 230, y: 28), color: color(1, 1, 1, 0.85))

    // Faint scan line to evoke video.
    ctx.setFillColor(color(1, 1, 1, 0.03))
    for y in stride(from: CGFloat(0), to: H, by: 4) {
        ctx.fill(CGRect(x: 0, y: y, width: W, height: 1))
    }
}

func writePNG(_ ctx: CGContext, to url: URL) {
    guard let image = ctx.makeImage() else { return }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Scene builders
//
// Each function paints one scene to the supplied context. CoreGraphics
// uses a bottom-left origin (y grows upward), which makes "ground" and
// "sky" math straightforward but is worth remembering when reading
// coordinates below.

func drawFrontPorch(_ ctx: CGContext) {
    // Sky → wall gradient (full canvas backdrop).
    fillGradient(ctx,
        colors: [color(0.82, 0.78, 0.70), color(0.55, 0.48, 0.40)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0),
        extendEnds: true)
    // Wood porch floor.
    rect(ctx, CGRect(x: 0, y: 0, width: W, height: H * 0.30), color(0.32, 0.22, 0.14))
    for i in 0..<8 {
        let y = H * 0.30 - CGFloat(i) * (H * 0.30 / 8)
        ctx.setStrokeColor(color(0, 0, 0, 0.18))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: W, y: y))
        ctx.strokePath()
    }
    // Doormat.
    roundedRect(ctx, CGRect(x: W / 2 - 180, y: H * 0.30 - 14, width: 360, height: 50), radius: 4, color(0.18, 0.12, 0.08))
    // Door frame.
    let doorX = W * 0.34, doorW = W * 0.32
    rect(ctx, CGRect(x: doorX - 18, y: H * 0.30, width: doorW + 36, height: H * 0.66), color(0.92, 0.88, 0.80))
    // Door.
    let doorRect = CGRect(x: doorX, y: H * 0.30, width: doorW, height: H * 0.60)
    rect(ctx, doorRect, color(0.20, 0.34, 0.42))
    // Door panels.
    for col in 0..<2 {
        for row in 0..<3 {
            let pw = doorW * 0.36
            let ph = H * 0.13
            let px = doorX + doorW * 0.12 + CGFloat(col) * (doorW * 0.44)
            let py = H * 0.34 + CGFloat(row) * (H * 0.16)
            roundedRect(ctx, CGRect(x: px, y: py, width: pw, height: ph), radius: 4, color(0.16, 0.28, 0.36))
        }
    }
    // Door knob.
    ctx.setFillColor(color(0.85, 0.72, 0.40))
    ctx.addArc(center: CGPoint(x: doorX + doorW - 30, y: H * 0.30 + H * 0.30), radius: 8, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    // Small package on the doormat.
    roundedRect(ctx, CGRect(x: W / 2 - 60, y: H * 0.30 + 8, width: 120, height: 70), radius: 4, color(0.78, 0.66, 0.48))
    ctx.setStrokeColor(color(0.6, 0.5, 0.35))
    ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: W / 2, y: H * 0.30 + 8))
    ctx.addLine(to: CGPoint(x: W / 2, y: H * 0.30 + 78))
    ctx.strokePath()
    applyCameraChrome(ctx, timestamp: "2026-05-12  08:32:14", label: "Front Door")
}

func drawDriveway(_ ctx: CGContext) {
    // Twilight sky (full canvas backdrop).
    fillGradient(ctx,
        colors: [color(0.95, 0.62, 0.40), color(0.30, 0.32, 0.48), color(0.12, 0.14, 0.24)],
        locations: [0, 0.55, 1],
        from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: H),
        extendEnds: true)
    // Distant ridge.
    ctx.setFillColor(color(0.18, 0.16, 0.22))
    ctx.move(to: CGPoint(x: 0, y: H * 0.42))
    ctx.addLine(to: CGPoint(x: W * 0.18, y: H * 0.48))
    ctx.addLine(to: CGPoint(x: W * 0.35, y: H * 0.44))
    ctx.addLine(to: CGPoint(x: W * 0.58, y: H * 0.50))
    ctx.addLine(to: CGPoint(x: W * 0.82, y: H * 0.46))
    ctx.addLine(to: CGPoint(x: W, y: H * 0.50))
    ctx.addLine(to: CGPoint(x: W, y: H * 0.42))
    ctx.closePath()
    ctx.fillPath()
    // Driveway tarmac, vanishing-point perspective.
    ctx.setFillColor(color(0.18, 0.18, 0.20))
    ctx.move(to: CGPoint(x: W * 0.30, y: H * 0.42))
    ctx.addLine(to: CGPoint(x: W * 0.70, y: H * 0.42))
    ctx.addLine(to: CGPoint(x: W * 1.10, y: 0))
    ctx.addLine(to: CGPoint(x: W * -0.10, y: 0))
    ctx.closePath()
    ctx.fillPath()
    // Dashed center line.
    ctx.setStrokeColor(color(0.92, 0.88, 0.70, 0.7))
    ctx.setLineWidth(6)
    ctx.setLineDash(phase: 0, lengths: [24, 18])
    ctx.move(to: CGPoint(x: W * 0.50, y: H * 0.42))
    ctx.addLine(to: CGPoint(x: W * 0.50, y: 0))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    // Garage in the distance.
    let garageX = W * 0.34, garageY = H * 0.40, garageW = W * 0.32, garageH = H * 0.18
    rect(ctx, CGRect(x: garageX, y: garageY, width: garageW, height: garageH), color(0.78, 0.74, 0.68))
    rect(ctx, CGRect(x: garageX + 10, y: garageY + 10, width: garageW - 20, height: garageH - 28), color(0.20, 0.20, 0.22))
    // Garage door panels.
    for i in 0..<4 {
        let y = garageY + 16 + CGFloat(i) * ((garageH - 30) / 4)
        ctx.setStrokeColor(color(0, 0, 0, 0.3))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: garageX + 12, y: y))
        ctx.addLine(to: CGPoint(x: garageX + garageW - 12, y: y))
        ctx.strokePath()
    }
    // Roof above garage.
    ctx.setFillColor(color(0.34, 0.30, 0.26))
    ctx.move(to: CGPoint(x: garageX - 8, y: garageY + garageH))
    ctx.addLine(to: CGPoint(x: garageX + garageW + 8, y: garageY + garageH))
    ctx.addLine(to: CGPoint(x: garageX + garageW * 0.5, y: garageY + garageH + H * 0.08))
    ctx.closePath()
    ctx.fillPath()
    applyCameraChrome(ctx, timestamp: "2026-05-12  20:14:07", label: "Driveway")
}

func drawBackyard(_ ctx: CGContext) {
    // Sky (top 58% of frame).
    fillGradient(ctx,
        colors: [color(0.50, 0.74, 0.88), color(0.78, 0.88, 0.92)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: H * 0.42),
        clipTo: CGRect(x: 0, y: H * 0.42, width: W, height: H * 0.58))
    // Distant trees along the horizon.
    for i in 0..<14 {
        let cx = CGFloat(i) * (W / 13)
        let cy = H * 0.42
        let rr = CGFloat.random(in: 30...62, using: &seed)
        ctx.setFillColor(color(0.18, 0.34, 0.22, 0.85))
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rr, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
    // Lawn (bottom 42% of frame).
    fillGradient(ctx,
        colors: [color(0.30, 0.52, 0.28), color(0.18, 0.36, 0.20)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H * 0.42), to: CGPoint(x: 0, y: 0),
        clipTo: CGRect(x: 0, y: 0, width: W, height: H * 0.42))
    // Wooden fence across the middle.
    let fenceY = H * 0.36
    ctx.setFillColor(color(0.45, 0.32, 0.20))
    ctx.fill(CGRect(x: 0, y: fenceY, width: W, height: 18))
    for i in 0..<20 {
        let x = CGFloat(i) * (W / 20)
        ctx.setFillColor(color(0.50, 0.36, 0.22))
        ctx.fill(CGRect(x: x, y: fenceY - 60, width: W / 20 - 6, height: 80))
        // Knot detail.
        ctx.setFillColor(color(0.30, 0.20, 0.10, 0.7))
        ctx.addArc(center: CGPoint(x: x + (W / 20) / 2 - 3, y: fenceY - 30), radius: 3, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
    // Patio set in the foreground.
    let chairX = W * 0.18, chairY: CGFloat = 80
    roundedRect(ctx, CGRect(x: chairX, y: chairY, width: 120, height: 12), radius: 3, color(0.88, 0.88, 0.86))
    roundedRect(ctx, CGRect(x: chairX + 8, y: chairY - 60, width: 12, height: 60), radius: 3, color(0.88, 0.88, 0.86))
    roundedRect(ctx, CGRect(x: chairX + 100, y: chairY - 60, width: 12, height: 60), radius: 3, color(0.88, 0.88, 0.86))
    // BBQ silhouette.
    roundedRect(ctx, CGRect(x: W * 0.70, y: 60, width: 180, height: 100), radius: 10, color(0.16, 0.16, 0.18))
    rect(ctx, CGRect(x: W * 0.74, y: 30, width: 10, height: 30), color(0.16, 0.16, 0.18))
    rect(ctx, CGRect(x: W * 0.82, y: 30, width: 10, height: 30), color(0.16, 0.16, 0.18))
    applyCameraChrome(ctx, timestamp: "2026-05-12  14:08:51", label: "Backyard")
}

func drawGarageInterior(_ ctx: CGContext) {
    // Wall (full canvas backdrop).
    fillGradient(ctx,
        colors: [color(0.62, 0.58, 0.52), color(0.42, 0.38, 0.34)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0),
        extendEnds: true)
    // Concrete floor (bottom 38%).
    fillGradient(ctx,
        colors: [color(0.34, 0.34, 0.36), color(0.20, 0.20, 0.22)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H * 0.38), to: CGPoint(x: 0, y: 0),
        clipTo: CGRect(x: 0, y: 0, width: W, height: H * 0.38))
    // Garage door (closed) on the back wall.
    let doorX = W * 0.28, doorY = H * 0.38, doorW = W * 0.44, doorH = H * 0.45
    rect(ctx, CGRect(x: doorX, y: doorY, width: doorW, height: doorH), color(0.78, 0.78, 0.78))
    for i in 0..<6 {
        let y = doorY + CGFloat(i) * doorH / 6
        ctx.setStrokeColor(color(0, 0, 0, 0.18))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: doorX, y: y))
        ctx.addLine(to: CGPoint(x: doorX + doorW, y: y))
        ctx.strokePath()
    }
    // Shelves on the left wall.
    for i in 0..<4 {
        let y = H * 0.45 + CGFloat(i) * 70
        rect(ctx, CGRect(x: 30, y: y, width: 180, height: 6), color(0.40, 0.30, 0.20))
        // Boxes on shelves.
        if i % 2 == 0 {
            roundedRect(ctx, CGRect(x: 50, y: y + 6, width: 60, height: 44), radius: 4, color(0.78, 0.66, 0.46))
            roundedRect(ctx, CGRect(x: 120, y: y + 6, width: 70, height: 44), radius: 4, color(0.55, 0.55, 0.58))
        }
    }
    // Bicycle silhouette on the right.
    ctx.setStrokeColor(color(0, 0, 0, 0.7))
    ctx.setLineWidth(4)
    ctx.addArc(center: CGPoint(x: W * 0.82, y: 80), radius: 40, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.addArc(center: CGPoint(x: W * 0.94, y: 80), radius: 40, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: W * 0.82, y: 80))
    ctx.addLine(to: CGPoint(x: W * 0.88, y: 130))
    ctx.addLine(to: CGPoint(x: W * 0.94, y: 80))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: W * 0.88, y: 130))
    ctx.addLine(to: CGPoint(x: W * 0.86, y: 160))
    ctx.strokePath()
    applyCameraChrome(ctx, timestamp: "2026-05-12  17:42:33", label: "Garage")
}

func drawSideGate(_ ctx: CGContext) {
    // Late-afternoon ambient (top 45%).
    fillGradient(ctx,
        colors: [color(0.66, 0.78, 0.84), color(0.50, 0.62, 0.70)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: H * 0.55),
        clipTo: CGRect(x: 0, y: H * 0.55, width: W, height: H * 0.45))
    // Cobblestone path (bottom 55%).
    fillGradient(ctx,
        colors: [color(0.55, 0.50, 0.46), color(0.32, 0.30, 0.28)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H * 0.55), to: CGPoint(x: 0, y: 0),
        clipTo: CGRect(x: 0, y: 0, width: W, height: H * 0.55))
    // Cobble pattern.
    for r in 0..<10 {
        for c in 0..<14 {
            let x = CGFloat(c) * (W / 13) + (r % 2 == 0 ? 0 : W / 26)
            let y = CGFloat(r) * (H * 0.55 / 9)
            ctx.setFillColor(color(0.40, 0.36, 0.34, 0.6))
            ctx.addArc(center: CGPoint(x: x, y: y), radius: 18, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.fillPath()
        }
    }
    // Wooden side fence rising on each side, gate in the middle.
    let fenceTop = H * 0.78
    for side in [CGFloat(0), W * 0.62] {
        let x = side
        rect(ctx, CGRect(x: x, y: H * 0.20, width: W * 0.38, height: fenceTop - H * 0.20), color(0.45, 0.32, 0.22))
        for i in 0..<6 {
            let px = x + 8 + CGFloat(i) * (W * 0.38 / 6)
            rect(ctx, CGRect(x: px, y: H * 0.20, width: 38, height: fenceTop - H * 0.20), color(0.55, 0.40, 0.26))
        }
    }
    // Gate.
    let gateX = W * 0.38, gateW = W * 0.24, gateY = H * 0.26, gateH = H * 0.50
    rect(ctx, CGRect(x: gateX, y: gateY, width: gateW, height: gateH), color(0.38, 0.28, 0.20))
    for i in 0..<5 {
        let px = gateX + 10 + CGFloat(i) * (gateW / 5)
        rect(ctx, CGRect(x: px, y: gateY + 10, width: 28, height: gateH - 20), color(0.50, 0.36, 0.24))
    }
    // Iron hinges.
    ctx.setFillColor(color(0.08, 0.08, 0.08))
    ctx.fill(CGRect(x: gateX + 4, y: gateY + 30, width: 30, height: 12))
    ctx.fill(CGRect(x: gateX + 4, y: gateY + gateH - 42, width: 30, height: 12))
    applyCameraChrome(ctx, timestamp: "2026-05-12  16:21:09", label: "Side Gate")
}

func drawHallway(_ ctx: CGContext) {
    // Interior wall warm wash (full canvas backdrop).
    fillGradient(ctx,
        colors: [color(0.92, 0.86, 0.74), color(0.62, 0.54, 0.42)],
        locations: [0, 1],
        from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0),
        extendEnds: true)
    // Wooden floor receding to a vanishing point.
    ctx.setFillColor(color(0.42, 0.28, 0.18))
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: W, y: 0))
    ctx.addLine(to: CGPoint(x: W * 0.62, y: H * 0.42))
    ctx.addLine(to: CGPoint(x: W * 0.38, y: H * 0.42))
    ctx.closePath()
    ctx.fillPath()
    // Floor plank lines.
    for i in 1..<10 {
        let t = CGFloat(i) / 10
        let yStart = H * 0.42 * (1 - t * 0.8)
        let xLeft = W * 0.38 + (W * -0.38) * t * 0.6
        let xRight = W * 0.62 + (W * 0.38) * t * 0.6
        ctx.setStrokeColor(color(0, 0, 0, 0.2))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: xLeft, y: yStart))
        ctx.addLine(to: CGPoint(x: xRight, y: yStart))
        ctx.strokePath()
    }
    // Side walls.
    ctx.setFillColor(color(0.70, 0.62, 0.50))
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: 0, y: H))
    ctx.addLine(to: CGPoint(x: W * 0.38, y: H * 0.42))
    ctx.closePath()
    ctx.fillPath()
    ctx.setFillColor(color(0.78, 0.70, 0.58))
    ctx.move(to: CGPoint(x: W, y: 0))
    ctx.addLine(to: CGPoint(x: W, y: H))
    ctx.addLine(to: CGPoint(x: W * 0.62, y: H * 0.42))
    ctx.closePath()
    ctx.fillPath()
    // Doorway at the end.
    let doorW = W * 0.10, doorH = H * 0.36
    let doorX = W * 0.5 - doorW / 2
    let doorY = H * 0.18
    rect(ctx, CGRect(x: doorX, y: doorY, width: doorW, height: doorH), color(0.20, 0.16, 0.12))
    // Picture frames on left wall.
    for i in 0..<3 {
        let cx = W * 0.10 + CGFloat(i) * W * 0.10
        let cy = H * 0.62 - CGFloat(i) * H * 0.06
        let fw: CGFloat = 70, fh: CGFloat = 90
        roundedRect(ctx, CGRect(x: cx - fw / 2, y: cy - fh / 2, width: fw, height: fh), radius: 2, color(0.95, 0.94, 0.90))
        rect(ctx, CGRect(x: cx - fw / 2 + 8, y: cy - fh / 2 + 8, width: fw - 16, height: fh - 16), color(0.50, 0.66, 0.72))
    }
    applyCameraChrome(ctx, timestamp: "2026-05-12  09:55:02", label: "Hallway")
}

// Deterministic PRNG so re-running the script produces identical PNGs —
// useful for committing the output to the repo without spurious diffs.
struct DeterministicGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var seed = DeterministicGenerator(state: 0xC0DEFACE)

// MARK: - Render all scenes

let scenes: [(slug: String, draw: (CGContext) -> Void)] = [
    ("front-door",       drawFrontPorch),
    ("driveway",         drawDriveway),
    ("backyard",         drawBackyard),
    ("garage",           drawGarageInterior),
    ("side-gate",        drawSideGate),
    ("hallway",          drawHallway),
]

for (slug, draw) in scenes {
    let ctx = newContext()
    draw(ctx)
    let url = outDir.appendingPathComponent("\(slug).png")
    writePNG(ctx, to: url)
    FileHandle.standardOutput.write(Data("Wrote \(url.path)\n".utf8))
}

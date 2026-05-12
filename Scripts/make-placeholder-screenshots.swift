#!/usr/bin/env swift
// Generate landing-page-ready placeholder screenshots that show the app
// chrome (window title bar, sidebar, toolbar, tile borders) wrapped
// around the stylized "stock camera view" PNGs produced by
// make-stock-camera-views.swift.
//
// Why both scripts:
//   - make-stock-camera-views.swift produces the inner camera-view
//     imagery (front door, driveway, backyard, etc.).
//   - this script wraps them in app chrome and writes the final PNGs
//     to docs/screenshots/, ready to commit and serve from reolens.io.
//
// The previous version produced labeled "Screenshot coming soon"
// placeholders; this version renders something the user can actually
// ship while the real captures get re-shot. Run with:
//
//   ./Scripts/make-stock-camera-views.swift
//   ./Scripts/make-placeholder-screenshots.swift
//
// Outputs:
//   docs/screenshots/grid-adaptive.png
//   docs/screenshots/spotlight.png
//   docs/screenshots/detail-ptz.png
//   docs/screenshots/notification.png
//   docs/screenshots/about.png
//
// To replace any of these with a real screenshot later, capture the
// app, run Scripts/composite-screenshot.sh to drop stock scenes into
// the tile regions (avoids publishing real footage), and overwrite
// the same filename.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

let W: CGFloat = 2400
let H: CGFloat = 1500

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let stockDir = repoRoot.appendingPathComponent("docs/assets/stock-cameras")
let outDir = repoRoot.appendingPathComponent("docs/screenshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()

// MARK: - Color & text helpers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let bgWindow      = rgb(0.11, 0.12, 0.14)
let bgSidebar     = rgb(0.14, 0.15, 0.18)
let bgContent     = rgb(0.09, 0.10, 0.12)
let strokeFaint   = rgb(1, 1, 1, 0.07)
let strokeMid     = rgb(1, 1, 1, 0.12)
let textPrimary   = rgb(0.95, 0.95, 0.97)
let textSecondary = rgb(0.95, 0.95, 0.97, 0.55)
let textTertiary  = rgb(0.95, 0.95, 0.97, 0.35)
let accent        = rgb(0.30, 0.78, 1.0)

func newContext(width: CGFloat = W, height: CGFloat = H) -> CGContext {
    CGContext(
        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
        bytesPerRow: Int(width) * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
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

func roundedRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, fill: CGColor? = nil, stroke: (CGColor, CGFloat)? = nil) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if let fill {
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    if let (s, lw) = stroke {
        ctx.addPath(path)
        ctx.setStrokeColor(s)
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }
}

func fill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.fill(r)
}

// MARK: - Stock scene loader

/// Loads a stock camera PNG and draws it into `rect`, scaled to fill
/// (cropped if needed) so it behaves like the app's `.resizeAspectFill`
/// streaming view. Falls back to a dark fill when the file is missing,
/// which keeps the script useful before make-stock-camera-views has
/// been run.
func drawStockScene(_ ctx: CGContext, slug: String, into target: CGRect) {
    let url = stockDir.appendingPathComponent("\(slug).png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        fill(ctx, target, rgb(0.05, 0.05, 0.07))
        drawText(ctx, "(missing \(slug).png)", fontSize: 18, at: CGPoint(x: target.midX - 80, y: target.midY), color: textTertiary)
        return
    }
    let srcW = CGFloat(image.width)
    let srcH = CGFloat(image.height)
    let srcAspect = srcW / srcH
    let dstAspect = target.width / target.height
    let drawRect: CGRect
    if srcAspect > dstAspect {
        // Source is wider → fit height, crop sides.
        let h = target.height
        let w = h * srcAspect
        drawRect = CGRect(x: target.midX - w / 2, y: target.minY, width: w, height: h)
    } else {
        // Source is taller → fit width, crop top/bottom.
        let w = target.width
        let h = w / srcAspect
        drawRect = CGRect(x: target.minX, y: target.midY - h / 2, width: w, height: h)
    }
    ctx.saveGState()
    ctx.clip(to: target)
    ctx.draw(image, in: drawRect)
    ctx.restoreGState()
}

// MARK: - Chrome

/// Pseudo macOS window chrome — title bar with three traffic lights and
/// a rounded outer border. Returns the inner content rect (sidebar +
/// detail combined) so the caller can lay out the rest of the UI.
func drawWindowChrome(_ ctx: CGContext) -> CGRect {
    // Outer rounded window background.
    let outer = CGRect(x: 30, y: 30, width: W - 60, height: H - 60)
    roundedRect(ctx, outer, radius: 14, fill: bgWindow, stroke: (strokeMid, 1))

    // Title bar.
    let titleBarH: CGFloat = 60
    let titleRect = CGRect(x: outer.minX, y: outer.maxY - titleBarH, width: outer.width, height: titleBarH)
    fill(ctx, titleRect, rgb(0.16, 0.17, 0.20))
    fill(ctx, CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 1), strokeFaint)
    for (i, c) in [rgb(0.92, 0.34, 0.32), rgb(0.95, 0.74, 0.22), rgb(0.32, 0.78, 0.34)].enumerated() {
        ctx.setFillColor(c)
        ctx.addArc(center: CGPoint(x: titleRect.minX + 32 + CGFloat(i) * 26, y: titleRect.midY), radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
    drawText(ctx, "Reolens", fontSize: 18, weight: 0.4, at: CGPoint(x: outer.midX - 38, y: titleRect.midY - 7), color: textPrimary)

    let content = CGRect(x: outer.minX + 1, y: outer.minY + 1, width: outer.width - 2, height: outer.height - titleBarH - 1)
    fill(ctx, content, bgContent)
    return content
}

/// Sidebar list of devices. Returns the detail rect to its right.
func drawSidebar(_ ctx: CGContext, in content: CGRect) -> CGRect {
    let sbW: CGFloat = 280
    let sb = CGRect(x: content.minX, y: content.minY, width: sbW, height: content.height)
    fill(ctx, sb, bgSidebar)
    fill(ctx, CGRect(x: sb.maxX, y: sb.minY, width: 1, height: sb.height), strokeFaint)

    drawText(ctx, "DEVICES", fontSize: 11, weight: 0.5, at: CGPoint(x: sb.minX + 20, y: sb.maxY - 60), color: textTertiary)
    drawText(ctx, "+", fontSize: 24, weight: 0.4, at: CGPoint(x: sb.maxX - 36, y: sb.maxY - 70), color: textSecondary)

    let deviceNames = ["Home Hub", "Front Door", "Driveway", "Backyard", "Garage"]
    let rowH: CGFloat = 56
    let firstY = sb.maxY - 100
    for (i, name) in deviceNames.enumerated() {
        let y = firstY - CGFloat(i) * (rowH + 8)
        let r = CGRect(x: sb.minX + 12, y: y - rowH + 12, width: sb.width - 24, height: rowH)
        if i == 1 {
            roundedRect(ctx, r, radius: 8, fill: rgb(0.22, 0.42, 0.62, 0.55))
        }
        ctx.setFillColor(textSecondary)
        ctx.addArc(center: CGPoint(x: r.minX + 18, y: r.midY), radius: 5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        drawText(ctx, name, fontSize: 15, weight: 0.3, at: CGPoint(x: r.minX + 36, y: r.midY - 5), color: textPrimary)
        if i == 0 {
            drawText(ctx, "192.168.1.40 · 5 channels", fontSize: 11, at: CGPoint(x: r.minX + 36, y: r.midY - 22), color: textTertiary)
        }
        ctx.setFillColor(rgb(0.32, 0.78, 0.34))
        ctx.addArc(center: CGPoint(x: r.maxX - 12, y: r.midY), radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }

    let detail = CGRect(x: sb.maxX + 1, y: content.minY, width: content.width - sbW - 1, height: content.height)
    return detail
}

/// A tile (camera view inside the grid) with the stock scene + label
/// chip + optional badge.
func drawTile(_ ctx: CGContext, in r: CGRect, slug: String, label: String, isPrimary: Bool = false, badge: String? = nil) {
    ctx.saveGState()
    let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    drawStockScene(ctx, slug: slug, into: r)
    ctx.restoreGState()
    roundedRect(ctx, r, radius: 10, stroke: (rgb(1, 1, 1, 0.08), 1))
    let chipW: CGFloat = min(r.width * 0.7, 240)
    let chipH: CGFloat = 30
    let chip = CGRect(x: r.minX + 8, y: r.maxY - chipH - 8, width: chipW, height: chipH)
    roundedRect(ctx, chip, radius: 6, fill: rgb(0, 0, 0, 0.55))
    drawText(ctx, label, fontSize: 13, weight: 0.4, at: CGPoint(x: chip.minX + 12, y: chip.midY - 5), color: textPrimary)
    if let badge {
        let bw: CGFloat = 28, bh: CGFloat = 28
        let b = CGRect(x: r.maxX - bw - 8, y: r.maxY - bh - 8, width: bw, height: bh)
        roundedRect(ctx, b, radius: 14, fill: rgb(0.95, 0.74, 0.22, 0.95))
        drawText(ctx, badge, fontSize: 16, weight: 0.5, at: CGPoint(x: b.midX - 5, y: b.midY - 7), color: rgb(0, 0, 0, 0.85))
    }
    if isPrimary {
        ctx.setStrokeColor(rgb(0.95, 0.78, 0.30, 0.7))
        ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 2, dy: 2), cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.strokePath()
    }
}

// MARK: - Writer

func write(_ ctx: CGContext, to name: String, width: CGFloat = W, height: CGFloat = H) {
    let url = outDir.appendingPathComponent(name)
    guard let image = ctx.makeImage() else { return }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    FileHandle.standardOutput.write(Data("Wrote \(url.path) (\(Int(width))×\(Int(height)))\n".utf8))
}

// MARK: - Adaptive grid

func renderAdaptiveGrid() {
    let ctx = newContext()
    fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), rgb(0.06, 0.07, 0.09))
    let content = drawWindowChrome(ctx)
    let detail = drawSidebar(ctx, in: content)

    let barH: CGFloat = 56
    let bar = CGRect(x: detail.minX, y: detail.maxY - barH, width: detail.width, height: barH)
    fill(ctx, bar, rgb(0.10, 0.11, 0.13))
    fill(ctx, CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1), strokeFaint)
    drawText(ctx, "Adaptive", fontSize: 14, weight: 0.4, at: CGPoint(x: bar.minX + 20, y: bar.midY - 5), color: textPrimary)
    drawText(ctx, "Long-press a tile to rearrange.", fontSize: 12, at: CGPoint(x: bar.minX + 140, y: bar.midY - 5), color: textTertiary)
    drawText(ctx, "5 cameras", fontSize: 12, at: CGPoint(x: bar.maxX - 120, y: bar.midY - 5), color: textSecondary)

    let area = CGRect(x: detail.minX + 16, y: detail.minY + 16, width: detail.width - 32, height: detail.height - barH - 32)
    let cols = 3
    let rows = 2
    let gap: CGFloat = 12
    let tileW = (area.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
    let tileH = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
    let tiles: [(slug: String, label: String, badge: String?)] = [
        ("front-door", "Front Door", "!"),
        ("driveway",   "Driveway",   nil),
        ("backyard",   "Backyard",   nil),
        ("garage",     "Garage",     nil),
        ("side-gate",  "Side Gate",  nil),
        ("hallway",    "Hallway",    nil),
    ]
    for (i, t) in tiles.enumerated() {
        let c = i % cols
        let r = i / cols
        let x = area.minX + CGFloat(c) * (tileW + gap)
        let y = area.maxY - CGFloat(r + 1) * tileH - CGFloat(r) * gap
        drawTile(ctx, in: CGRect(x: x, y: y, width: tileW, height: tileH), slug: t.slug, label: t.label, badge: t.badge)
    }

    write(ctx, to: "grid-adaptive.png")
}

// MARK: - Spotlight

func renderSpotlight() {
    let ctx = newContext()
    fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), rgb(0.06, 0.07, 0.09))
    let content = drawWindowChrome(ctx)
    let detail = drawSidebar(ctx, in: content)

    let barH: CGFloat = 56
    let bar = CGRect(x: detail.minX, y: detail.maxY - barH, width: detail.width, height: barH)
    fill(ctx, bar, rgb(0.10, 0.11, 0.13))
    drawText(ctx, "Spotlight", fontSize: 14, weight: 0.4, at: CGPoint(x: bar.minX + 20, y: bar.midY - 5), color: textPrimary)
    drawText(ctx, "Primary: Front Door", fontSize: 12, at: CGPoint(x: bar.minX + 160, y: bar.midY - 5), color: textSecondary)

    let area = CGRect(x: detail.minX + 16, y: detail.minY + 16, width: detail.width - 32, height: detail.height - barH - 32)
    let gap: CGFloat = 12
    let topH = (area.height - gap) * 0.75
    let bottomH = (area.height - gap) * 0.25
    let primaryW = (area.width - gap) * 0.75
    let rightColW = (area.width - gap) * 0.25
    drawTile(ctx, in: CGRect(x: area.minX, y: area.maxY - topH, width: primaryW, height: topH), slug: "front-door", label: "Front Door", isPrimary: true)
    let rightSlugs = [("driveway", "Driveway"), ("backyard", "Backyard"), ("garage", "Garage"), ("hallway", "Hallway")]
    let rTileH = (topH - 3 * gap) / 4
    for (i, t) in rightSlugs.enumerated() {
        let y = area.maxY - rTileH - CGFloat(i) * (rTileH + gap)
        drawTile(ctx, in: CGRect(x: area.minX + primaryW + gap, y: y, width: rightColW, height: rTileH), slug: t.0, label: t.1)
    }
    let bottomSlugs = [("side-gate", "Side Gate"), ("driveway", "Driveway"), ("backyard", "Backyard")]
    let bTileW = (area.width - 2 * gap) / 3
    for (i, t) in bottomSlugs.enumerated() {
        let x = area.minX + CGFloat(i) * (bTileW + gap)
        drawTile(ctx, in: CGRect(x: x, y: area.minY, width: bTileW, height: bottomH), slug: t.0, label: t.1)
    }

    write(ctx, to: "spotlight.png")
}

// MARK: - Detail + PTZ

func renderDetailPTZ() {
    let ctx = newContext()
    fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), rgb(0.06, 0.07, 0.09))
    let content = drawWindowChrome(ctx)
    let detail = drawSidebar(ctx, in: content)

    let inset: CGFloat = 24
    let view = CGRect(x: detail.minX + inset, y: detail.minY + 220, width: detail.width - 2 * inset, height: detail.height - 240 - 60)
    ctx.saveGState()
    let path = CGPath(roundedRect: view, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    drawStockScene(ctx, slug: "driveway", into: view)
    ctx.restoreGState()
    roundedRect(ctx, view, radius: 12, stroke: (rgb(1, 1, 1, 0.10), 1))

    drawText(ctx, "Driveway", fontSize: 22, weight: 0.5, at: CGPoint(x: view.minX + 22, y: view.maxY - 40), color: textPrimary)
    drawText(ctx, "Main · 2560×1920 · 15 fps · H.265", fontSize: 13, at: CGPoint(x: view.minX + 22, y: view.maxY - 64), color: textSecondary)

    let ptzH: CGFloat = 140
    let ptz = CGRect(x: detail.minX + inset, y: detail.minY + 50, width: detail.width - 2 * inset, height: ptzH)
    roundedRect(ctx, ptz, radius: 12, fill: rgb(0.10, 0.11, 0.13), stroke: (rgb(1, 1, 1, 0.05), 1))
    let padCx = ptz.minX + 90, padCy = ptz.midY
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        let cx = padCx + CGFloat(dx) * 40
        let cy = padCy + CGFloat(dy) * 40
        roundedRect(ctx, CGRect(x: cx - 22, y: cy - 22, width: 44, height: 44), radius: 8, fill: rgb(0.18, 0.20, 0.24))
    }
    roundedRect(ctx, CGRect(x: padCx - 22, y: padCy - 22, width: 44, height: 44), radius: 8, fill: rgb(0.24, 0.28, 0.34))
    let labels = ["Zoom −", "Zoom +", "Focus −", "Focus +"]
    for (i, label) in labels.enumerated() {
        let r = CGRect(x: padCx + 100 + CGFloat(i) * 130, y: padCy - 22, width: 110, height: 44)
        roundedRect(ctx, r, radius: 8, fill: rgb(0.18, 0.20, 0.24), stroke: (rgb(1, 1, 1, 0.05), 1))
        drawText(ctx, label, fontSize: 13, weight: 0.4, at: CGPoint(x: r.minX + 14, y: r.midY - 6), color: textPrimary)
    }
    let presets = ["Front Yard", "Mailbox", "Garage", "Driveway End"]
    for (i, p) in presets.enumerated() {
        let r = CGRect(x: ptz.maxX - 460 + CGFloat(i) * 110, y: padCy - 18, width: 100, height: 36)
        roundedRect(ctx, r, radius: 18, fill: rgb(0.22, 0.42, 0.62, 0.45), stroke: (rgb(0.30, 0.78, 1.0, 0.5), 1))
        drawText(ctx, p, fontSize: 12, weight: 0.4, at: CGPoint(x: r.minX + 12, y: r.midY - 5), color: textPrimary)
    }

    write(ctx, to: "detail-ptz.png")
}

// MARK: - Rich notification

func renderNotification() {
    let nw: CGFloat = 1200, nh: CGFloat = 600
    let ctx = newContext(width: nw, height: nh)
    fill(ctx, CGRect(x: 0, y: 0, width: nw, height: nh), rgb(0.08, 0.10, 0.14))
    let grad = CGGradient(colorsSpace: space, colors: [rgb(0.16, 0.20, 0.28), rgb(0.04, 0.06, 0.10)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: nh), end: CGPoint(x: 0, y: 0), options: [])
    let notif = CGRect(x: 600, y: 380, width: 540, height: 180)
    roundedRect(ctx, notif, radius: 16, fill: rgb(0.95, 0.95, 0.97))
    let iconR = CGRect(x: notif.minX + 16, y: notif.maxY - 16 - 56, width: 56, height: 56)
    roundedRect(ctx, iconR, radius: 12, fill: rgb(0.30, 0.55, 1.0))
    drawText(ctx, "R", fontSize: 36, weight: 0.6, at: CGPoint(x: iconR.midX - 10, y: iconR.midY - 14), color: rgb(1, 1, 1))
    drawText(ctx, "Reolens", fontSize: 12, weight: 0.4, at: CGPoint(x: iconR.maxX + 12, y: notif.maxY - 28), color: rgb(0.4, 0.4, 0.4))
    drawText(ctx, "Motion detected — Front Door", fontSize: 17, weight: 0.6, at: CGPoint(x: iconR.maxX + 12, y: notif.maxY - 54), color: rgb(0.08, 0.08, 0.10))
    drawText(ctx, "Person · 2026-05-12 08:32", fontSize: 13, at: CGPoint(x: iconR.maxX + 12, y: notif.maxY - 74), color: rgb(0.35, 0.35, 0.40))
    let thumb = CGRect(x: notif.maxX - 130, y: notif.minY + 16, width: 110, height: 148)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.clip()
    drawStockScene(ctx, slug: "front-door", into: thumb)
    ctx.restoreGState()
    write(ctx, to: "notification.png", width: nw, height: nh)
}

// MARK: - About panel

/// Measures the rendered width of a string at a given font size + weight so
/// we can center labels without eyeballing magic offsets.
func measureText(_ string: String, fontSize: CGFloat, weight: CGFloat = 0) -> CGFloat {
    let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
    let attrs: [CFString: Any] = [
        kCTFontTraitsAttribute: traits,
        kCTFontFamilyNameAttribute: "Helvetica Neue",
    ]
    let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
    let lineAttrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: textPrimary,
    ]
    let attr = CFAttributedStringCreate(nil, string as CFString, lineAttrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    _ = ascent; _ = descent; _ = leading
    return width
}

/// Draws `string` horizontally centered around `centerX` at baseline `y`.
func drawTextCentered(_ ctx: CGContext, _ string: String, fontSize: CGFloat, weight: CGFloat = 0, centerX: CGFloat, y: CGFloat, color: CGColor) {
    let w = measureText(string, fontSize: fontSize, weight: weight)
    drawText(ctx, string, fontSize: fontSize, weight: weight, at: CGPoint(x: centerX - w / 2, y: y), color: color)
}

/// Render the macOS About panel — proper window chrome (traffic lights,
/// title bar) and proper portrait proportions, matching the look of a real
/// `NSApplication.orderFrontStandardAboutPanel` window.
func renderAbout() {
    let aw: CGFloat = 540, ah: CGFloat = 720
    let ctx = newContext(width: aw, height: ah)

    // Transparent page background — the page CSS handles surroundings; the
    // window itself fills the rounded rect.
    fill(ctx, CGRect(x: 0, y: 0, width: aw, height: ah), rgb(0.07, 0.08, 0.10))

    let margin: CGFloat = 22
    let outer = CGRect(x: margin, y: margin, width: aw - margin * 2, height: ah - margin * 2)
    roundedRect(ctx, outer, radius: 14, fill: bgWindow, stroke: (strokeMid, 1))

    // Title bar (top of the window). CG origin is bottom-left, so the
    // title bar sits at outer.maxY.
    let titleBarH: CGFloat = 44
    let titleRect = CGRect(x: outer.minX, y: outer.maxY - titleBarH, width: outer.width, height: titleBarH)
    fill(ctx, titleRect, rgb(0.16, 0.17, 0.20))
    fill(ctx, CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 1), strokeFaint)
    for (i, c) in [rgb(0.92, 0.34, 0.32), rgb(0.95, 0.74, 0.22), rgb(0.32, 0.78, 0.34)].enumerated() {
        ctx.setFillColor(c)
        ctx.addArc(center: CGPoint(x: titleRect.minX + 22 + CGFloat(i) * 22, y: titleRect.midY), radius: 6.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
    drawTextCentered(ctx, "About Reolens", fontSize: 13, weight: 0.3, centerX: outer.midX, y: titleRect.midY - 5, color: textSecondary)

    // Content area. Lay out by distance from the top of the content rect.
    let content = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: outer.height - titleBarH)
    let centerX = content.midX
    let topY = content.maxY  // top of content area; subtract to walk down

    // App icon (128px) — pulled from the real bundle icon so it stays in sync.
    let iconSize: CGFloat = 128
    let iconRect = CGRect(x: centerX - iconSize / 2, y: topY - 48 - iconSize, width: iconSize, height: iconSize)
    let iconURL = repoRoot.appendingPathComponent("docs/assets/icon-256.png")
    if let src = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        ctx.draw(img, in: iconRect)
    } else {
        roundedRect(ctx, iconRect, radius: 28, fill: accent)
    }

    // App name + version + description, walking down from below the icon.
    var cursor = iconRect.minY - 36
    drawTextCentered(ctx, "Reolens", fontSize: 30, weight: 0.5, centerX: centerX, y: cursor, color: textPrimary)
    cursor -= 26
    drawTextCentered(ctx, "Version 0.3.0", fontSize: 13, centerX: centerX, y: cursor, color: textSecondary)
    cursor -= 34
    drawTextCentered(ctx, "A native client for Reolink cameras", fontSize: 13, centerX: centerX, y: cursor, color: textSecondary)
    cursor -= 18
    drawTextCentered(ctx, "on macOS, iPad, and iPhone.", fontSize: 13, centerX: centerX, y: cursor, color: textSecondary)

    // "Check for Updates…" rendered as a real-looking pill button.
    let btnLabel = "Check for Updates…"
    let btnLabelW = measureText(btnLabel, fontSize: 13, weight: 0.4)
    let btnPadX: CGFloat = 18
    let btnH: CGFloat = 28
    let btnW = btnLabelW + btnPadX * 2
    cursor -= 36
    let btnRect = CGRect(x: centerX - btnW / 2, y: cursor - btnH + 8, width: btnW, height: btnH)
    roundedRect(ctx, btnRect, radius: 6, fill: rgb(0.22, 0.24, 0.28), stroke: (strokeMid, 1))
    drawTextCentered(ctx, btnLabel, fontSize: 13, weight: 0.4, centerX: centerX, y: btnRect.midY - 5, color: accent)

    // Footer — subtle divider, then domain + copyright.
    let dividerY = content.minY + 70
    fill(ctx, CGRect(x: content.minX + 28, y: dividerY, width: content.width - 56, height: 1), strokeFaint)
    drawTextCentered(ctx, "reolens.io", fontSize: 12, weight: 0.3, centerX: centerX, y: dividerY - 22, color: textSecondary)
    drawTextCentered(ctx, "© 2026 J&E Stats · MIT licensed", fontSize: 11, centerX: centerX, y: dividerY - 40, color: textTertiary)

    write(ctx, to: "about.png", width: aw, height: ah)
}

// MARK: - Render all

renderAdaptiveGrid()
renderSpotlight()
renderDetailPTZ()
renderNotification()
renderAbout()

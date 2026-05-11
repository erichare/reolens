#!/usr/bin/env swift
// Generate the social/OpenGraph image (1200×630) for reolens.io.
//
// Centered app icon on the same slate-blue → indigo gradient as the icon
// itself, with the wordmark to the right. Output: docs/assets/og.png.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

let W: CGFloat = 1200
let H: CGFloat = 630

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconURL = repoRoot.appendingPathComponent("Resources/icon-master.png")
let outURL = repoRoot.appendingPathComponent("docs/assets/og.png")

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
    bytesPerRow: Int(W) * 4, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("failed to allocate context\n", stderr); exit(1)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Backdrop gradient (matches the icon's palette).
let topColor = color(0.16, 0.34, 0.55)
let botColor = color(0.05, 0.08, 0.16)
let gradient = CGGradient(
    colorsSpace: space,
    colors: [topColor, botColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: W / 2, y: H),
    end: CGPoint(x: W / 2, y: 0),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// Subtle radial glow behind the icon.
let glow = CGGradient(
    colorsSpace: space,
    colors: [color(0.30, 0.82, 1.0, 0.25), color(0.30, 0.82, 1.0, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 380, y: H / 2), startRadius: 0,
    endCenter:   CGPoint(x: 380, y: H / 2), endRadius: 320,
    options: []
)

// Icon.
guard let iconSrc = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(iconSrc, 0, nil) else {
    fputs("failed to read \(iconURL.path)\n", stderr); exit(1)
}
let iconSize: CGFloat = 320
ctx.draw(icon, in: CGRect(x: 220, y: (H - iconSize) / 2, width: iconSize, height: iconSize))

// Wordmark (CoreText). System bold, white.
let title = "Reolens"
let subtitle = "A modern macOS client for Reolink cameras"

func drawText(_ string: String, fontSize: CGFloat, weight: CGFloat, at point: CGPoint, alpha: CGFloat = 1) {
    // Build a CTFont from the system font with the requested weight.
    // CTFontCreateUIFontForLanguage doesn't take a weight, so use the
    // attribute-traits route through CTFontDescriptor.
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

drawText(title, fontSize: 92, weight: 700, at: CGPoint(x: 600, y: H / 2 + 12))
drawText(subtitle, fontSize: 28, weight: 400, at: CGPoint(x: 600, y: H / 2 - 40), alpha: 0.85)

// Write PNG.
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("failed to create image dest\n", stderr); exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")

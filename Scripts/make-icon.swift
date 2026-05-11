#!/usr/bin/env swift
// Generate the Reolens app icon master (1024×1024 PNG) using CoreGraphics.
//
// Reproducible, no external dependencies — only the macOS SDK. Run from the
// repo root:
//
//     swift Scripts/make-icon.swift
//
// Output: Resources/icon-master.png
//
// Design: dark teal-to-indigo squircle backdrop with a centered "lens / eye"
// glyph (camera-aperture ring + cyan iris + dark pupil + specular highlight)
// and a small recording-indicator dot. Flat, modern, scales cleanly to 16 px.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let SIZE: CGFloat = 1024

// MARK: - Output path (Resources/icon-master.png at repo root)

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let outputDir = repoRoot.appendingPathComponent("Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outputURL = outputDir.appendingPathComponent("icon-master.png")

// MARK: - Drawing helpers

let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func makeContext() -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: Int(SIZE),
        height: Int(SIZE),
        bitsPerComponent: 8,
        bytesPerRow: Int(SIZE) * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write(Data("failed to allocate bitmap context\n".utf8))
        exit(1)
    }
    return ctx
}

let ctx = makeContext()

// Transparent backdrop — the squircle handles its own shape.
ctx.setFillColor(color(0, 0, 0, 0))
ctx.fill(CGRect(x: 0, y: 0, width: SIZE, height: SIZE))

// MARK: - Background squircle (gradient-filled)

let inset = SIZE * 0.045
let bgRect = CGRect(x: inset, y: inset, width: SIZE - 2 * inset, height: SIZE - 2 * inset)
let bgRadius = SIZE * 0.225  // matches macOS Big Sur+ squircle curvature

ctx.saveGState()
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let topColor = color(0.16, 0.34, 0.55)   // slate blue
let bottomColor = color(0.07, 0.13, 0.24) // deep indigo
let gradient = CGGradient(
    colorsSpace: space,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: SIZE / 2, y: SIZE - inset),
    end:   CGPoint(x: SIZE / 2, y: inset),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()

// MARK: - Lens body

let cx = SIZE / 2
let cy = SIZE / 2
let outerR = SIZE * 0.30
let ringW = SIZE * 0.045

ctx.saveGState()
ctx.setStrokeColor(color(0.95, 0.97, 1.0, 0.95))
ctx.setLineWidth(ringW)
ctx.beginPath()
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: outerR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Iris (cyan disc)
let irisR = outerR * 0.62
ctx.saveGState()
ctx.setFillColor(color(0.10, 0.65, 0.85))
ctx.beginPath()
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: irisR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()
ctx.restoreGState()

// Pupil
let pupilR = irisR * 0.45
ctx.saveGState()
ctx.setFillColor(color(0.05, 0.08, 0.16))
ctx.beginPath()
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: pupilR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()
ctx.restoreGState()

// Specular highlight
let hiR = pupilR * 0.42
let hx = cx - pupilR * 0.35
let hy = cy + pupilR * 0.35
ctx.saveGState()
ctx.setFillColor(color(1.0, 1.0, 1.0, 0.92))
ctx.beginPath()
ctx.addArc(center: CGPoint(x: hx, y: hy), radius: hiR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()
ctx.restoreGState()

// MARK: - Write PNG

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("failed to render CGImage\n".utf8))
    exit(1)
}

let pngType = UTType.png.identifier as CFString
guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, pngType, 1, nil) else {
    FileHandle.standardError.write(Data("failed to create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("failed to finalize PNG\n".utf8))
    exit(1)
}

print("wrote \(outputURL.path)")

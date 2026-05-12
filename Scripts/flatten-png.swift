#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: flatten-png.swift input.png output.png\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("failed to read \(inputURL.path)\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("failed to allocate bitmap context\n".utf8))
    exit(1)
}

let background = CGColor(colorSpace: colorSpace, components: [0.07, 0.13, 0.24, 1.0])!
let rect = CGRect(x: 0, y: 0, width: width, height: height)
ctx.setFillColor(background)
ctx.fill(rect)
ctx.draw(image, in: rect)

guard let flattened = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("failed to prepare output \(outputURL.path)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("failed to write \(outputURL.path)\n".utf8))
    exit(1)
}

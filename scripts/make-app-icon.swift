#!/usr/bin/env swift
// Renders the Claude Manager app icon into the AppIcon.appiconset.
// Run:  swift scripts/make-app-icon.swift
// Cosmetic and deterministic — regenerate whenever the design changes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: "Sources/ClaudeManagerApp/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high

    // Squircle background with a warm coral gradient.
    let inset = s * 0.06
    let shape = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = shape.width * 0.2237
    ctx.saveGState()
    ctx.addPath(roundedRect(shape, radius: radius))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [srgb(233, 141, 106), srgb(193, 95, 60)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Three stacked "profile cards", back to front, offset diagonally.
    let card = s * 0.34
    let cardRadius = card * 0.24
    let center = CGPoint(x: s / 2, y: s / 2)
    let offsets: [(CGFloat, CGFloat, Double)] = [(-0.11, 0.11, 0.35), (-0.055, 0.055, 0.55), (0, 0, 1)]
    for (dx, dy, alpha) in offsets {
        let origin = CGPoint(x: center.x - card / 2 + dx * s, y: center.y - card / 2 - dy * s)
        let rect = CGRect(x: origin.x, y: origin.y, width: card, height: card)
        ctx.addPath(roundedRect(rect, radius: cardRadius))
        ctx.setFillColor(srgb(255, 255, 255, alpha))
        ctx.fillPath()
    }

    // Accent badge on the front card (bottom-right), echoing a launcher badge.
    let front = CGRect(x: center.x - card / 2, y: center.y - card / 2, width: card, height: card)
    let badgeR = card * 0.2
    let badgeCenter = CGPoint(x: front.maxX - badgeR * 0.8, y: front.minY + badgeR * 0.8)
    ctx.addPath(CGPath(
        ellipseIn: CGRect(
            x: badgeCenter.x - badgeR,
            y: badgeCenter.y - badgeR,
            width: badgeR * 2,
            height: badgeR * 2
        ),
        transform: nil
    ))
    ctx.setFillColor(srgb(10, 132, 255))
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    try? (data as Data).write(to: url)
}

let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]
for size in pixelSizes {
    writePNG(render(size), to: outDir.appendingPathComponent("icon_\(size).png"))
}

let contents = """
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(pixelSizes.count) PNGs + Contents.json to \(outDir.path)")

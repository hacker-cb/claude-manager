import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws a macOS-style colored badge (rounded pill + white ring + centered label)
/// over the real app icon, entirely with CoreGraphics/CoreText — no AppKit and no
/// window server, so it runs headlessly in `swift test` and CI.
///
/// Geometry is expressed in CoreGraphics' native bottom-left coordinate space
/// (the badge sits in the bottom-right corner).
public struct BadgeRenderer {
    public init() {}

    /// Composite the badge onto `base`, returning a same-size image.
    public func drawBadge(on base: CGImage, label: String, color: RGBAColor) throws -> CGImage {
        let size = max(base.width, base.height)
        guard let ctx = Self.makeContext(size: size) else {
            throw ClaudeManagerError.iconGenerationFailed("could not create bitmap context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))

        let w = CGFloat(size)
        let h = (w * 0.34).rounded()
        let fontSize = h * 0.62

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let white = Self.cgColor(RGBAColor(red: 255, green: 255, blue: 255))
        let text = label.isEmpty ? " " : label
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: white
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else {
            throw ClaudeManagerError.iconGenerationFailed("could not lay out badge text")
        }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let padding = h * 0.28
        let pillWidth = max(h, textWidth + 2 * padding)
        let inset = w * 0.055
        let ring = w * 0.018

        let x2 = w - inset
        let x1 = x2 - pillWidth
        let y1 = inset
        let y2 = y1 + h

        // White ring behind the pill.
        let ringRect = CGRect(
            x: x1 - ring,
            y: y1 - ring,
            width: (x2 - x1) + 2 * ring,
            height: (y2 - y1) + 2 * ring
        )
        let ringRadius = (h + 2 * ring) / 2
        ctx.addPath(CGPath(
            roundedRect: ringRect,
            cornerWidth: ringRadius,
            cornerHeight: ringRadius,
            transform: nil
        ))
        ctx.setFillColor(white)
        ctx.fillPath()

        // Colored pill.
        let pillRect = CGRect(x: x1, y: y1, width: pillWidth, height: h)
        let pillRadius = h / 2
        ctx.addPath(CGPath(
            roundedRect: pillRect,
            cornerWidth: pillRadius,
            cornerHeight: pillRadius,
            transform: nil
        ))
        ctx.setFillColor(Self.cgColor(color))
        ctx.fillPath()

        // Centered label (non-flipped context → upright text).
        ctx.textPosition = CGPoint(
            x: pillRect.midX - textWidth / 2,
            y: pillRect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else {
            throw ClaudeManagerError.iconGenerationFailed("could not render composited icon")
        }
        return image
    }

    /// Produce the full `.iconset` (all standard sizes) as PNG bytes.
    public func makeIconSet(base: CGImage, label: String, color: RGBAColor) throws -> [IconImageSize: Data] {
        let composited = try drawBadge(on: base, label: label, color: color)
        var result: [IconImageSize: Data] = [:]
        for size in IconImageSize.standardSet {
            result[size] = try Self.encodePNG(Self.resize(composited, to: size.pixels))
        }
        return result
    }

    /// Render a single-size PNG for a live UI preview.
    public func renderPreviewPNG(base: CGImage, label: String, color: RGBAColor, pixels: Int) throws -> Data {
        let composited = try drawBadge(on: base, label: label, color: color)
        return try Self.encodePNG(Self.resize(composited, to: pixels))
    }

    // MARK: - CoreGraphics helpers

    static func makeContext(size: Int) -> CGContext? {
        guard size > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }

    static func resize(_ image: CGImage, to pixels: Int) throws -> CGImage {
        guard let ctx = makeContext(size: pixels) else {
            throw ClaudeManagerError.iconGenerationFailed("could not create resize context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let out = ctx.makeImage() else {
            throw ClaudeManagerError.iconGenerationFailed("could not resize icon")
        }
        return out
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ClaudeManagerError.iconGenerationFailed("could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClaudeManagerError.iconGenerationFailed("could not encode PNG")
        }
        return data as Data
    }
}

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

    /// Composite the badge onto `base`, returning a same-size image. `style` drives
    /// all geometry (size, shape, corner, ring, font); `.default` reproduces the
    /// original look.
    public func drawBadge(
        on base: CGImage,
        label: String,
        color: RGBAColor,
        style: BadgeStyle = .default
    ) throws -> CGImage {
        let size = max(base.width, base.height)
        guard let ctx = Self.makeContext(size: size) else {
            throw ClaudeManagerError.iconGenerationFailed("could not create bitmap context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))

        let w = CGFloat(size)
        let h = (w * style.scale).rounded()
        let fontSize = h * 0.62

        let white = Self.cgColor(RGBAColor(red: 255, green: 255, blue: 255))
        let drawn = style.drawnLabel(from: label)
        let text = drawn.isEmpty ? " " : drawn
        let fontName = style.fontWeight.fontName
        var laid = try Self.layoutLine(text, fontName: fontName, fontSize: fontSize, color: white)

        let inset = w * 0.055
        let ring = w * style.ringWidth
        let padding = h * 0.28
        // A circle keeps a fixed square footprint; the other shapes grow with the
        // text but never wider than the icon minus its insets, so the badge (and its
        // ring, since ringWidth ≤ inset) can never run off-canvas — even at max scale
        // with a long label.
        let maxPillWidth = w - 2 * inset
        let pillWidth = style.shape == .circle
            ? h
            : min(max(h, laid.width + 2 * padding), maxPillWidth)
        let pillRadius = style.shape == .roundedSquare ? h * 0.28 : h / 2

        // Shrink the glyphs uniformly if they'd spill past the pill's interior, so a
        // long label at any scale (or a wide label in a fixed-size circle) stays inside
        // the badge instead of being clipped by the icon edge.
        let interior = pillWidth - 2 * padding
        if laid.width > interior, interior > 0 {
            laid = try Self.layoutLine(
                text, fontName: fontName, fontSize: fontSize * (interior / laid.width), color: white
            )
        }

        // Bottom-left origin: "top" is high y, "trailing" is high x.
        let x1 = style.corner.isTrailing ? (w - inset - pillWidth) : inset
        let y1 = style.corner.isTop ? (w - inset - h) : inset
        let pillRect = CGRect(x: x1, y: y1, width: pillWidth, height: h)

        // White ring behind the pill (skipped when disabled).
        if ring > 0 {
            let ringRect = pillRect.insetBy(dx: -ring, dy: -ring)
            let ringRadius = pillRadius + ring
            ctx.addPath(CGPath(
                roundedRect: ringRect,
                cornerWidth: ringRadius,
                cornerHeight: ringRadius,
                transform: nil
            ))
            ctx.setFillColor(white)
            ctx.fillPath()
        }

        // Colored pill.
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
            x: pillRect.midX - laid.width / 2,
            y: pillRect.midY - (laid.ascent - laid.descent) / 2
        )
        CTLineDraw(laid.line, ctx)

        guard let image = ctx.makeImage() else {
            throw ClaudeManagerError.iconGenerationFailed("could not render composited icon")
        }
        return image
    }

    /// Produce the full `.iconset` (all standard sizes) as PNG bytes.
    public func makeIconSet(
        base: CGImage,
        label: String,
        color: RGBAColor,
        style: BadgeStyle = .default
    ) throws -> [IconImageSize: Data] {
        let composited = try drawBadge(on: base, label: label, color: color, style: style)
        var result: [IconImageSize: Data] = [:]
        for size in IconImageSize.standardSet {
            result[size] = try Self.encodePNG(Self.resize(composited, to: size.pixels))
        }
        return result
    }

    /// Render a single-size PNG for a live UI preview.
    public func renderPreviewPNG(
        base: CGImage,
        label: String,
        color: RGBAColor,
        style: BadgeStyle = .default,
        pixels: Int
    ) throws -> Data {
        let composited = try drawBadge(on: base, label: label, color: color, style: style)
        return try Self.encodePNG(Self.resize(composited, to: pixels))
    }

    // MARK: - CoreGraphics helpers

    private struct LaidOutLine {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Lay out a single line of white badge text and measure it, so the caller can
    /// size the pill and, if needed, re-lay-out at a smaller font to fit.
    private static func layoutLine(
        _ text: String,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor
    ) throws -> LaidOutLine {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else {
            throw ClaudeManagerError.iconGenerationFailed("could not lay out badge text")
        }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return LaidOutLine(line: line, width: width, ascent: ascent, descent: descent)
    }

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

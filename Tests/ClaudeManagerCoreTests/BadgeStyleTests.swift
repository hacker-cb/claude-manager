import CoreGraphics
import Foundation
import Testing
@testable import ClaudeManagerCore

struct BadgeStyleTests {
    @Test
    func defaultMatchesTheOriginalLook() {
        let d = BadgeStyle.default
        #expect(d.scale == 0.34)
        #expect(d.shape == .pill)
        #expect(d.corner == .bottomTrailing)
        #expect(d.ringWidth == 0.018)
        #expect(d.fontWeight == .bold)
        #expect(d.fontWeight.fontName == "HelveticaNeue-Bold")
        #expect(d.uppercase)
        #expect(d.maxLabelLength == 3)
    }

    @Test
    func initClampsOutOfRangeValues() {
        let tooBig = BadgeStyle(scale: 9, ringWidth: 9, maxLabelLength: 99)
        #expect(tooBig.scale == BadgeStyle.scaleRange.upperBound)
        #expect(tooBig.ringWidth == BadgeStyle.ringRange.upperBound)
        #expect(tooBig.maxLabelLength == BadgeStyle.labelLengthRange.upperBound)

        let tooSmall = BadgeStyle(scale: -1, ringWidth: -1, maxLabelLength: 0)
        #expect(tooSmall.scale == BadgeStyle.scaleRange.lowerBound)
        #expect(tooSmall.ringWidth == BadgeStyle.ringRange.lowerBound)
        #expect(tooSmall.maxLabelLength == BadgeStyle.labelLengthRange.lowerBound)
    }

    @Test
    func codableRoundTrips() throws {
        let style = BadgeStyle(
            scale: 0.4, shape: .circle, corner: .topLeading,
            ringWidth: 0, fontWeight: .light, uppercase: false, maxLabelLength: 2
        )
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(BadgeStyle.self, from: data)
        #expect(decoded == style)
    }

    @Test
    func decodeIsLenientAndReclamps() throws {
        // A missing key falls back to the default; an out-of-range value is clamped.
        let json = #"{"scale": 99, "shape": "circle"}"#
        let decoded = try JSONDecoder().decode(BadgeStyle.self, from: Data(json.utf8))
        #expect(decoded.scale == BadgeStyle.scaleRange.upperBound) // clamped, not 99
        #expect(decoded.shape == .circle)
        #expect(decoded.corner == BadgeStyle.default.corner) // filled from default
        #expect(decoded.maxLabelLength == BadgeStyle.default.maxLabelLength)
    }

    @Test
    func decodeRejectsNothingAndNeverThrows() throws {
        // Even an empty object yields a valid, fully-defaulted style.
        let decoded = try JSONDecoder().decode(BadgeStyle.self, from: Data("{}".utf8))
        #expect(decoded == BadgeStyle.default)
    }

    @Test
    func decodeSurvivesUnknownEnumAndTypeMismatch() throws {
        // An unknown enum raw (e.g. a value from a newer version) and a mistyped field
        // each fall back to their own default; valid fields survive — no throw.
        let json = #"{"shape": "hexagon", "scale": "big", "corner": "topLeading"}"#
        let decoded = try JSONDecoder().decode(BadgeStyle.self, from: Data(json.utf8))
        #expect(decoded.shape == BadgeStyle.default.shape) // unknown → default
        #expect(decoded.scale == BadgeStyle.default.scale) // mistyped → default
        #expect(decoded.corner == .topLeading) // valid → kept
    }

    @Test
    func drawnLabelUppercasesAndTruncates() {
        let up = BadgeStyle(uppercase: true, maxLabelLength: 3)
        #expect(up.drawnLabel(from: "workspace") == "WOR")

        let raw = BadgeStyle(uppercase: false, maxLabelLength: 4)
        #expect(raw.drawnLabel(from: "workspace") == "work")

        #expect(up.drawnLabel(from: "") == "")
    }
}

/// Verifies the style actually reaches the pixels: geometry knobs change the output,
/// and the style threads all the way through `IconPipeline`.
struct BadgeStyleRenderingTests {
    private let renderer = BadgeRenderer()

    @Test
    func largerScaleCoversMorePixels() throws {
        let base = try Fixture.solidImage(size: 256, color: RGBAColor(red: 20, green: 20, blue: 20))
        let small = try render(base, style: BadgeStyle(scale: 0.22))
        let large = try render(base, style: BadgeStyle(scale: 0.45))
        #expect(changedPixels(base, large) > changedPixels(base, small))
    }

    @Test
    func circleIsNarrowerThanPillForAWideLabel() throws {
        let base = try Fixture.solidImage(size: 256, color: RGBAColor(red: 20, green: 20, blue: 20))
        let label = "WWWWWW"
        let pill = try render(base, label: label, style: BadgeStyle(shape: .pill, maxLabelLength: 6))
        let circle = try render(base, label: label, style: BadgeStyle(shape: .circle, maxLabelLength: 6))
        // The pill grows with the text; the circle keeps a fixed square footprint.
        #expect(changedPixels(base, pill) > changedPixels(base, circle))
    }

    @Test
    func disablingTheRingReducesTheFootprint() throws {
        let base = try Fixture.solidImage(size: 256, color: RGBAColor(red: 20, green: 20, blue: 20))
        let ringed = try render(base, style: BadgeStyle(ringWidth: 0.04))
        let bare = try render(base, style: BadgeStyle(ringWidth: 0))
        #expect(changedPixels(base, ringed) > changedPixels(base, bare))
    }

    @Test
    func cornerMovesTheBadge() throws {
        let base = try Fixture.solidImage(size: 256, color: RGBAColor(red: 20, green: 20, blue: 20))
        let br = try centroid(base, render(base, style: BadgeStyle(corner: .bottomTrailing)))
        let tl = try centroid(base, render(base, style: BadgeStyle(corner: .topLeading)))
        // bottom-trailing sits at high x / high row; top-leading at low x / low row.
        #expect(br.x > tl.x)
        #expect(br.y > tl.y)
    }

    @Test
    func styleThreadsThroughIconPipeline() throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try Fixture.makeFakeRealApp(in: root, iconData: Fixture.baseICNSData())
        let pipeline = IconPipeline(packer: IcnsPacker(runner: SystemCommandRunner()))

        let plain = try pipeline.makeBadgeICNS(realClaude: real, label: "WK", color: .named("blue"))
        let styled = try pipeline.makeBadgeICNS(
            realClaude: real, label: "WK", color: .named("blue"),
            style: BadgeStyle(scale: 0.45, shape: .circle, corner: .topLeading)
        )
        #expect(plain != styled)
    }

    @Test
    func extremeStyleStaysWithinTheIcon() throws {
        let size = 256
        let base = try Fixture.solidImage(size: size, color: RGBAColor(red: 20, green: 20, blue: 20))
        // Max scale + longest label in a trailing corner would push the pill off the
        // left edge without the pill-width clamp; the badge must stay on-canvas.
        let style = BadgeStyle(scale: 0.45, shape: .pill, corner: .bottomTrailing, maxLabelLength: 6)
        let out = try render(base, label: "WWWWWW", style: style)
        // Locate the pill by its saturated red fill (not a diff vs base, which carries
        // ±1 edge noise from re-drawing the base). Without the clamp the pill would be
        // drawn from a negative x and its red would reach column 0.
        let bounds = try pillBounds(out)
        #expect(bounds.minX > 0)
        #expect(bounds.maxX < size - 1)
    }

    @Test
    func longLabelTextIsShrunkToStayInsideTheBadge() throws {
        let size = 256
        let base = try Fixture.solidImage(size: size, color: RGBAColor(red: 20, green: 20, blue: 20))
        // A wide label in a fixed-size circle would spill its white glyphs far past the
        // badge without shrink-to-fit; the text must stay within the pill + its ring.
        let style = BadgeStyle(scale: 0.34, shape: .circle, ringWidth: 0.02, maxLabelLength: 6)
        let out = try render(base, label: "MMMMMM", style: style)
        let pill = try pillBounds(out)
        let white = try whiteBoundsX(out)
        let ringSlack = Int((0.02 * Double(size)).rounded()) + 3
        #expect(white.minX >= pill.minX - ringSlack)
        #expect(white.maxX <= pill.maxX + ringSlack)
    }

    // MARK: - Pixel helpers

    private func pillBounds(_ image: CGImage) throws -> (minX: Int, maxX: Int) {
        // Saturated red = the pill fill; skip the dark base and the white ring/text.
        try boundsX(image) { $0 > 150 && $1 < 120 && $2 < 120 }
    }

    private func whiteBoundsX(_ image: CGImage) throws -> (minX: Int, maxX: Int) {
        // White = the ring and the glyphs (the base is dark, the pill is red).
        try boundsX(image) { $0 > 200 && $1 > 200 && $2 > 200 }
    }

    private func boundsX(
        _ image: CGImage,
        _ isMatch: (UInt8, UInt8, UInt8) -> Bool
    ) throws -> (minX: Int, maxX: Int) {
        let px = try rgbaBytes(image)
        let width = image.width
        var minX = width, maxX = -1
        var i = 0
        while i < px.count {
            if isMatch(px[i], px[i + 1], px[i + 2]) {
                let x = (i / 4) % width
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            i += 4
        }
        guard maxX >= 0 else { throw Fixture.FixtureError(message: "no matching pixels") }
        return (minX, maxX)
    }

    private func render(_ base: CGImage, label: String = "WK", style: BadgeStyle) throws -> CGImage {
        try renderer.drawBadge(
            on: base,
            label: label,
            color: RGBAColor(red: 240, green: 40, blue: 40),
            style: style
        )
    }

    private func pixelDiffers(_ a: [UInt8], _ b: [UInt8], _ i: Int) -> Bool {
        a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]
    }

    private func changedPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard let pa = try? rgbaBytes(a), let pb = try? rgbaBytes(b) else { return 0 }
        let end = min(pa.count, pb.count)
        var count = 0
        var i = 0
        while i < end {
            if pixelDiffers(pa, pb, i) { count += 1 }
            i += 4
        }
        return count
    }

    private func centroid(_ base: CGImage, _ badged: CGImage) throws -> (x: Double, y: Double) {
        let pa = try rgbaBytes(base)
        let pb = try rgbaBytes(badged)
        let width = badged.width
        let end = min(pa.count, pb.count)
        var sumX = 0.0, sumY = 0.0, count = 0.0
        var i = 0
        while i < end {
            if pixelDiffers(pa, pb, i) {
                let pixel = i / 4
                sumX += Double(pixel % width)
                sumY += Double(pixel / width)
                count += 1
            }
            i += 4
        }
        guard count > 0 else { throw Fixture.FixtureError(message: "no changed pixels") }
        return (sumX / count, sumY / count)
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &bytes, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw Fixture.FixtureError(message: "no context") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}

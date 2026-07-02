import CoreGraphics
import Foundation
import Testing
@testable import ClaudeManagerCore

struct IconRenderingTests {
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test
    func drawBadgePreservesSize() throws {
        let base = try Fixture.solidImage(size: 256, color: RGBAColor(red: 30, green: 30, blue: 30))
        let out = try BadgeRenderer().drawBadge(
            on: base,
            label: "W",
            color: RGBAColor(red: 255, green: 0, blue: 0)
        )
        #expect(out.width == 256)
        #expect(out.height == 256)
    }

    @Test
    func makeIconSetCoversAllStandardSizesAsPNG() throws {
        let base = try Fixture.solidImage(size: 512, color: RGBAColor(red: 30, green: 30, blue: 30))
        let set = try BadgeRenderer().makeIconSet(
            base: base,
            label: "WK",
            color: RGBAColor(red: 10, green: 200, blue: 90)
        )
        #expect(Set(set.keys) == Set(IconImageSize.standardSet))
        for (size, data) in set {
            #expect(data.prefix(8) == pngSignature, "size \(size.pixels) not PNG")
        }
    }

    @Test
    func icnsPackerEmitsValidICNSMagic() throws {
        let data = try Fixture.baseICNSData()
        #expect(data.prefix(4) == Data("icns".utf8))
        #expect(data.count > 100)
    }

    @Test
    func badgeChangesImageMeaningfully() throws {
        let size = 256
        let base = try Fixture.solidImage(size: size, color: RGBAColor(red: 20, green: 20, blue: 20))
        let badged = try BadgeRenderer().drawBadge(
            on: base,
            label: "X",
            color: RGBAColor(red: 255, green: 0, blue: 0)
        )
        let baseBytes = try rgbaBytes(base)
        let badgedBytes = try rgbaBytes(badged)
        #expect(baseBytes != badgedBytes)
        let changed = zip(baseBytes, badgedBytes).lazy.count(where: { $0 != $1 })
        // The badge covers a sizeable corner — expect well more than a few pixels.
        #expect(changed > size * 4)
    }

    @Test
    func iconImageSizeFileNames() {
        #expect(IconImageSize(points: 16, scale: 1).iconsetFileName == "icon_16x16.png")
        #expect(IconImageSize(points: 512, scale: 2).iconsetFileName == "icon_512x512@2x.png")
        #expect(IconImageSize(points: 256, scale: 2).pixels == 512)
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
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

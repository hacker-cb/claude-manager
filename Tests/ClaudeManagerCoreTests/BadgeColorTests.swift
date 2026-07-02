import Testing
@testable import ClaudeManagerCore

struct BadgeColorTests {
    @Test
    func parsesNamedPaletteColorsCaseInsensitively() throws {
        #expect(try BadgeColor.parse("blue") == .named("blue"))
        #expect(try BadgeColor.parse("GREEN") == .named("green"))
        #expect(try BadgeColor.parse("  Purple  ") == .named("purple"))
    }

    @Test
    func parsesHexColors() throws {
        let color = try BadgeColor.parse("#FF9F0A")
        #expect(color == .custom(RGBAColor(red: 255, green: 159, blue: 10)))
        #expect(color.storageString == "#FF9F0A")
    }

    @Test
    func rejectsUnknownNameAndBadHex() {
        #expect(throws: ClaudeManagerError.self) { try BadgeColor.parse("mauve") }
        #expect(throws: ClaudeManagerError.self) { try BadgeColor.parse("#FFF") }
        #expect(throws: ClaudeManagerError.self) { try BadgeColor.parse("#GGGGGG") }
    }

    @Test
    func resolvesRGBAWithBlueFallbackForUnknownName() {
        #expect(BadgeColor.named("blue").rgba == RGBAColor(red: 10, green: 132, blue: 255))
        // Unknown name never crashes — falls back to the first palette entry.
        #expect(BadgeColor.named("nope").rgba == BadgeColor.palette[0].color)
    }

    @Test
    func storageStringRoundTrips() throws {
        for entry in BadgeColor.palette {
            let parsed = try BadgeColor.parse(entry.name)
            #expect(parsed.storageString == entry.name)
        }
        let custom = BadgeColor.custom(RGBAColor(red: 1, green: 2, blue: 3))
        #expect(try BadgeColor.parse(custom.storageString) == custom)
    }

    @Test
    func hexStringIsUppercaseSixDigits() {
        #expect(RGBAColor(red: 0, green: 0, blue: 0).hexString == "#000000")
        #expect(RGBAColor(red: 255, green: 255, blue: 255).hexString == "#FFFFFF")
    }
}

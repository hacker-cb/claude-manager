import Testing
@testable import ClaudeManagerCore

struct VersionOrderTests {
    @Test
    func comparesNumericallyNotLexicographically() {
        #expect(VersionOrder.isNewer("1.18286.0", than: "1.17377.2"))
        #expect(!VersionOrder.isNewer("1.17377.2", than: "1.18286.0"))
        // A string compare would rank "1.9" above "1.18" — the numeric compare must not.
        #expect(VersionOrder.isNewer("1.18", than: "1.9"))
    }

    @Test
    func missingTrailingComponentsReadAsZero() {
        #expect(!VersionOrder.isNewer("1.18", than: "1.18.0"))
        #expect(!VersionOrder.isNewer("1.18.0", than: "1.18"))
        #expect(VersionOrder.isNewer("1.18.1", than: "1.18"))
    }

    @Test
    func malformedVersionNeverReadsAsNewer() {
        // Garbage components fold to 0, so a malformed string can't trip the prompt.
        #expect(!VersionOrder.isNewer("abc", than: "1.0"))
        #expect(VersionOrder.isNewer("1.0", than: "abc"))
        #expect(VersionOrder.compare("2.0", "2.0") == .orderedSame)
    }
}

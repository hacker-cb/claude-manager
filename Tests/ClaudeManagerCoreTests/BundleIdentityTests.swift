import Testing
@testable import ClaudeManagerCore

struct BundleIdentityTests {
    /// An Info.plist fragment declaring `schemes` as a single `CFBundleURLTypes` entry.
    private func info(schemes: [String]) -> [String: Any] {
        ["CFBundleURLTypes": [["CFBundleURLName": "test", "CFBundleURLSchemes": schemes]]]
    }

    @Test
    func findsADeclaredScheme() {
        #expect(BundleIdentity.declaresURLScheme("claude", in: info(schemes: ["claude"])))
    }

    /// The dev identity: it declares its own private scheme, so it must read as *not* an
    /// eligible `claude://` handler — the whole point of the build-time split.
    @Test
    func devSchemeDoesNotCountAsTheRealOne() {
        #expect(!BundleIdentity.declaresURLScheme("claude", in: info(schemes: ["claude-cmdev"])))
    }

    /// URL schemes are case-insensitive (RFC 3986 §3.1).
    @Test
    func matchesCaseInsensitively() {
        #expect(BundleIdentity.declaresURLScheme("claude", in: info(schemes: ["Claude"])))
        #expect(BundleIdentity.declaresURLScheme("CLAUDE", in: info(schemes: ["claude"])))
    }

    @Test
    func findsTheSchemeInAnyEntryOrPosition() {
        let multiEntry: [String: Any] = ["CFBundleURLTypes": [
            ["CFBundleURLSchemes": ["other"]],
            ["CFBundleURLSchemes": ["also-not-it", "claude"]]
        ]]
        #expect(BundleIdentity.declaresURLScheme("claude", in: multiEntry))
    }

    @Test
    func missingOrEmptyDeclarationsReadAsNotDeclared() {
        #expect(!BundleIdentity.declaresURLScheme("claude", in: nil))
        #expect(!BundleIdentity.declaresURLScheme("claude", in: [:]))
        #expect(!BundleIdentity.declaresURLScheme("claude", in: ["CFBundleURLTypes": []]))
        #expect(!BundleIdentity.declaresURLScheme("claude", in: info(schemes: [])))
    }

    /// One malformed *entry* must not mask a well-formed one that follows it.
    @Test
    func skipsMalformedEntriesWithoutMaskingGoodOnes() {
        let mixed: [String: Any] = ["CFBundleURLTypes": [
            ["CFBundleURLSchemes": "claude"], // a string where an array belongs
            ["CFBundleURLName": "no schemes key"],
            ["CFBundleURLSchemes": ["claude"]]
        ]]
        #expect(BundleIdentity.declaresURLScheme("claude", in: mixed))
    }

    /// A stray *non-dictionary* element in the array must not fail the whole lookup and
    /// hide a valid scheme in a well-formed sibling (the top-level `[Any]` cast, per-entry
    /// skip — regression guard for the earlier `[[String: Any]]` cast that failed closed).
    @Test
    func skipsNonDictionaryEntriesWithoutMaskingGoodOnes() {
        let mixed: [String: Any] = ["CFBundleURLTypes": [
            42, // a stray number
            "not a dict", // a stray string
            ["CFBundleURLSchemes": ["claude"]]
        ]]
        #expect(BundleIdentity.declaresURLScheme("claude", in: mixed))
    }

    @Test
    func aWronglyTypedURLTypesValueReadsAsNotDeclared() {
        #expect(!BundleIdentity.declaresURLScheme("claude", in: ["CFBundleURLTypes": "claude"]))
    }
}

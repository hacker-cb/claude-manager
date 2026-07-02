import Testing
@testable import ClaudeManagerCore

struct PathUtilsTests {
    @Test
    func abbreviatesHomePrefixOnly() {
        let home = "/Users/x"
        #expect(PathUtils.abbreviatingHome("/Users/x", home: home) == "~")
        #expect(PathUtils.abbreviatingHome("/Users/x/Library", home: home) == "~/Library")
        #expect(PathUtils.abbreviatingHome("/Users/xavier/Library", home: home) == "/Users/xavier/Library")
        #expect(PathUtils.abbreviatingHome("/opt/tools", home: home) == "/opt/tools")
    }

    @Test
    func regexEscapesMetacharacters() {
        let escaped = PathUtils.regexEscaped("/Applications/Claude Beta.app/Contents/MacOS/Claude")
        // Spaces stay literal; the dot before `app` is escaped so it matches a
        // literal `.` in the ps command line rather than any character.
        #expect(escaped == #"/Applications/Claude Beta\.app/Contents/MacOS/Claude"#)
        #expect(PathUtils.regexEscaped("a+b(c)") == #"a\+b\(c\)"#)
    }

    @Test
    func shellSingleQuotesEscapeEmbeddedQuotes() {
        #expect(PathUtils.shellSingleQuoted("/tmp/plain") == "'/tmp/plain'")
        #expect(PathUtils.shellSingleQuoted("a'b") == "'a'\\''b'")
    }
}

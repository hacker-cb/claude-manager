import Foundation
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

    /// What `absolutePath`'s `standardizingPath` stops short of, and what every "is this the
    /// same profile directory" question therefore has to go through.
    @Test
    func sameDirectoryFoldsSymlinksAndDotSegments() throws {
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("profiles")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("profiles-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(PathUtils.sameDirectory(link.path, real.path))
        #expect(PathUtils.sameDirectory(real.path + "/./", real.path))
        #expect(!PathUtils.sameDirectory(real.path, root.appendingPathComponent("other").path))
        // Never by string prefix: `…/profiles` is not `…/profiles-link`.
        #expect(!PathUtils.sameDirectory(real.path, real.path + "-link-elsewhere"))
    }

    /// Case is deliberately **not** folded. A case-insensitive volume makes two spellings one
    /// file, but this helper cannot know the volume — a caller needing that answer has to ask
    /// the file system, and pretending otherwise here would make two genuinely different
    /// directories on a case-sensitive volume compare equal.
    @Test
    func sameDirectoryDoesNotFoldCase() {
        #expect(!PathUtils.sameDirectory("/tmp/Work", "/tmp/work"))
        #expect(PathUtils.canonicalPath("/tmp/Work") != PathUtils.canonicalPath("/tmp/work"))
    }
}

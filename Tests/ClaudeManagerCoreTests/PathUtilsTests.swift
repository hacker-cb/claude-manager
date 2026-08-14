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

    /// Case is answered by the volume, not by a rule here: where two spellings open one
    /// directory they compare equal, and where the volume keeps them apart so does this. The
    /// expectation is derived from the volume the suite is running on rather than hardcoded,
    /// since both kinds are legal on macOS — and a hardcoded `/tmp/work` would additionally
    /// turn on whatever the machine happens to have on disk.
    @Test
    func sameDirectoryAnswersCaseTheWayTheVolumeDoes() throws {
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let upper = root.appendingPathComponent("Work")
        try fm.createDirectory(at: upper, withIntermediateDirectories: true)
        let lower = root.appendingPathComponent("work")
        let volumeIgnoresCase = fm.fileExists(atPath: lower.path)

        #expect(PathUtils.sameDirectory(upper.path, lower.path) == volumeIgnoresCase)
        // With nothing on disk to ask, the spelling is kept as given.
        let absent = root.appendingPathComponent("Absent")
        #expect(!PathUtils.sameDirectory(absent.path, root.appendingPathComponent("absent").path))
    }

    /// The answer must not turn on whether the directory exists. `resolvingSymlinksInPath`
    /// alone folds `/private/tmp/x` to `/tmp/x` only while `x` is on disk — and `sameDirectory`
    /// gates every `update`, `rebuild` and `remove`, so a launcher would go from editable to
    /// stuck the moment its data directory was deleted by hand.
    @Test
    func canonicalPathIsTheSameBeforeAndAfterTheDirectoryExists() throws {
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("data")
        let viaLink = root.appendingPathComponent("root-link").appendingPathComponent("data")
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("root-link"), withDestinationURL: root
        )

        #expect(PathUtils.sameDirectory(viaLink.path, target.path)) // before it exists
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(PathUtils.sameDirectory(viaLink.path, target.path)) // and after
    }

    /// Identity comes from the file system, and it is what tells a rename in place from a rename
    /// onto a stranger. Both readings of `…/Work` vs `…/WORK` are correct — on one volume they
    /// are one file, on the other two — and nothing in the strings distinguishes them, so this
    /// asserts against what the volume itself does.
    @Test
    func sameFileFollowsTheVolumeOnCase() throws {
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let upper = root.appendingPathComponent("Work")
        try Data("x".utf8).write(to: upper)
        let lower = root.appendingPathComponent("work")
        let volumeIgnoresCase = fm.fileExists(atPath: lower.path)

        #expect(PathUtils.sameFile(upper.path, lower.path) == volumeIgnoresCase)
        #expect(PathUtils.sameFile(upper.path, upper.path))
    }

    /// The two ways this must answer "no", both of which a caller reads as licence to write:
    /// a path with nothing at it, and a symlink weighed against the file it points at. A link
    /// and its target are two entries — moving one is not moving the other.
    @Test
    func sameFileSaysNoWithoutBothSidesOnDisk() throws {
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!PathUtils.sameFile(target.path, root.appendingPathComponent("absent").path))
        #expect(!PathUtils.sameFile(link.path, target.path))
        #expect(PathUtils.sameFile(link.path, link.path))
    }
}

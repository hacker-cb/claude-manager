import Foundation
import Testing
@testable import ClaudeManagerCore

struct LauncherScriptTests {
    let realBinary = "/Applications/Claude.app/Contents/MacOS/Claude"

    @Test
    func rendersExecLineWithProfile() {
        let script = LauncherScript.render(profilePath: "/data/work", realBinaryPath: realBinary)
        #expect(script.hasPrefix("#!/bin/bash"))
        #expect(script.contains(#"exec "$REAL" --user-data-dir="$PROFILE" "$@""#))
        #expect(script.contains("PROFILE='/data/work'"))
        #expect(script.contains("REAL='\(realBinary)'"))
    }

    @Test
    func embedsRegexEscapedDuplicateGuardPattern() {
        let script = LauncherScript.render(profilePath: "/data/p", realBinaryPath: realBinary)
        // The dot in `.app` is escaped and the profile is anchored with ( |$) so
        // `/p` never matches `/ps`.
        #expect(script
            .contains(
                #"PATTERN='^/Applications/Claude\.app/Contents/MacOS/Claude --user-data-dir=/data/p( |$)'"#
            ))
        #expect(script.contains(#"pgrep -f "$PATTERN""#))
        #expect(script.contains("osascript"))
    }

    @Test
    func usesShlockToCloseTheLaunchRace() {
        let script = LauncherScript.render(profilePath: "/data/work", realBinaryPath: realBinary)
        // The atomic guard: a lock inside the profile dir, claimed via shlock
        // before exec, with the pgrep guard kept only as a fallback.
        #expect(script.contains(#"LOCK="$PROFILE/.claude-manager.lock""#))
        #expect(script.contains(#"/usr/bin/shlock -f "$LOCK" -p $$"#))
        #expect(script.contains(#"mkdir -p "$PROFILE""#))
        #expect(script.contains("activate_existing"))
    }

    @Test
    func singleQuotesPathsWithSpaces() {
        let script = LauncherScript.render(
            profilePath: "/data/with space",
            realBinaryPath: "/Applications/Claude Beta.app/Contents/MacOS/Claude"
        )
        #expect(script.contains("PROFILE='/data/with space'"))
        #expect(script.contains("REAL='/Applications/Claude Beta.app/Contents/MacOS/Claude'"))
    }

    // MARK: - Behaviour of the rendered script (executed against a fake binary)

    /// With no lock held the launcher execs the "real" binary exactly once.
    @Test
    func launchesWhenNoInstanceHoldsTheLock() throws {
        let harness = try ScriptHarness()
        defer { harness.cleanup() }

        let status = harness.runLauncher()

        #expect(status == 0)
        #expect(harness.launchCount() == 1)
    }

    /// While a live process holds the profile lock, the launcher refuses to start a
    /// second instance — it exits cleanly without exec-ing the "real" binary.
    @Test
    func refusesToLaunchWhileTheLockIsHeldByALiveProcess() throws {
        let harness = try ScriptHarness()
        defer { harness.cleanup() }

        let holder = harness.holdLock()
        defer { holder.terminate() }

        let status = harness.runLauncher()

        #expect(status == 0)
        #expect(harness.launchCount() == 0)
    }
}

/// Builds a temp profile dir, a fake "real Claude" that just records each launch,
/// and the rendered launcher script — then runs the launcher and inspects the
/// recorded launches. Everything lives under a throwaway temp dir.
private struct ScriptHarness {
    let root: URL
    let profileDir: URL
    let launcher: URL
    let launchLog: URL
    let fileManager = FileManager.default

    init() throws {
        root = try Fixture.makeTempDir()
        profileDir = root.appendingPathComponent("profile", isDirectory: true)
        launchLog = root.appendingPathComponent("launches.log")
        let real = root.appendingPathComponent("fake-claude")
        launcher = root.appendingPathComponent("launcher.sh")

        // The fake "real" binary appends a line per launch and exits immediately.
        let realScript = """
        #!/bin/bash
        echo "launched" >> \(PathUtils.shellSingleQuoted(launchLog.path))
        """
        try Self.writeExecutable(realScript, to: real)

        let script = LauncherScript.render(profilePath: profileDir.path, realBinaryPath: real.path)
        try Self.writeExecutable(script, to: launcher)
    }

    /// Runs the launcher to completion and returns its exit status.
    func runLauncher() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher.path]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Spawns a long-lived process and hands the profile lock to it via shlock, so
    /// the launcher sees a live holder. Caller must `terminate()` it.
    func holdLock() -> Process {
        try? fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try? sleeper.run()

        let lock = profileDir.appendingPathComponent(".claude-manager.lock").path
        let shlock = Process()
        shlock.executableURL = URL(fileURLWithPath: "/usr/bin/shlock")
        shlock.arguments = ["-f", lock, "-p", String(sleeper.processIdentifier)]
        try? shlock.run()
        shlock.waitUntilExit()
        return sleeper
    }

    func launchCount() -> Int {
        guard let contents = try? String(contentsOf: launchLog, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

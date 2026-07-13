import Foundation
import Testing
@testable import ClaudeManagerCore

// `.serialized`: the two behaviour tests each spawn `bash`/`shlock`/`sleep`; running them
// serially keeps this suite from contending with itself for the process table under the
// otherwise-parallel test run.
@Suite(.serialized)
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

        let status = try harness.runLauncher()

        #expect(status == 0)
        #expect(harness.launchCount() == 1)
    }

    /// While a live process holds the profile lock, the launcher refuses to start a
    /// second instance — it exits cleanly without exec-ing the "real" binary.
    @Test
    func refusesToLaunchWhileTheLockIsHeldByALiveProcess() throws {
        let harness = try ScriptHarness()
        defer { harness.cleanup() }

        let holder = try harness.holdLock()
        defer { ScriptHarness.terminateAndReap(holder) }

        let status = try harness.runLauncher()

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

    /// Runs the launcher to completion and returns its exit status. Throws (rather
    /// than swallowing the spawn error) so a launcher that never starts fails the
    /// test loudly instead of passing on a stale `terminationStatus` of 0.
    func runLauncher() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher.path]
        try process.run()
        try Self.waitOrTerminate(process, seconds: 30, what: "launcher")
        return process.terminationStatus
    }

    /// Spawns a long-lived process and hands the profile lock to it via shlock, so
    /// the launcher sees a live holder. Throws if the sleeper or shlock fails so the
    /// test can't silently proceed with no lock actually held. Caller must
    /// `terminate()` (and wait for) the returned process.
    func holdLock() throws -> Process {
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()

        let lock = profileDir.appendingPathComponent(".claude-manager.lock").path
        let shlock = Process()
        shlock.executableURL = URL(fileURLWithPath: "/usr/bin/shlock")
        shlock.arguments = ["-f", lock, "-p", String(sleeper.processIdentifier)]
        do {
            try shlock.run()
            try Self.waitOrTerminate(shlock, seconds: 10, what: "shlock")
        } catch {
            Self.terminateAndReap(sleeper)
            throw error
        }
        guard shlock.terminationStatus == 0 else {
            Self.terminateAndReap(sleeper)
            throw Fixture
                .FixtureError(
                    message: "shlock failed to acquire the lock (status \(shlock.terminationStatus))"
                )
        }
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

    /// Wait for `process` to exit, but never longer than `seconds`. A wedged spawn — seen
    /// as multi-minute stalls under parallel test load, which once ran out the CI job's
    /// time budget — is terminated and surfaced as a failure here instead of hanging the
    /// whole run.
    ///
    /// Polls `isRunning` on the calling thread rather than blocking in `waitUntilExit()`:
    /// `Process.waitUntilExit()` services the *current* thread's run loop, so off a
    /// run-loop-bearing thread (a GCD worker) it never observes termination and stalls
    /// until the deadline. `isRunning` is a plain state read that needs no run loop, and a
    /// terminated process is reaped by `Process`'s own internal source, so `terminationStatus`
    /// is valid once the loop ends.
    private static func waitOrTerminate(_ process: Process, seconds: TimeInterval, what: String) throws {
        let deadline = monotonicNow + seconds
        while process.isRunning {
            if monotonicNow >= deadline {
                let pid = process.processIdentifier
                process.terminate()
                // SIGTERM is async; give it a brief grace so a wedged spawn doesn't trail
                // into later tests (bash/shlock/sleep all honor it and exit promptly).
                let graceEnd = monotonicNow + 2
                while process.isRunning, monotonicNow < graceEnd {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw Fixture.FixtureError(
                    message: "\(what) (pid \(pid)) did not exit within \(Int(seconds))s (terminated)"
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Terminate `process` and wait (bounded) for it to actually exit — a non-throwing
    /// teardown counterpart to `waitOrTerminate`, so cleanup never blocks in
    /// `waitUntilExit()` either. SIGTERM'd `sleep`/`shlock` exit promptly; the 2s cap only
    /// bounds a pathological holdout.
    fileprivate static func terminateAndReap(_ process: Process) {
        process.terminate()
        let end = monotonicNow + 2
        while process.isRunning, monotonicNow < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Monotonic seconds for interval deadlines — unaffected by the wall-clock (NTP)
    /// jumps that `Date()` is subject to.
    private static var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

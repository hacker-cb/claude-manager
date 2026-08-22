import Foundation
import Testing
@testable import ClaudeManagerCore

struct ShipItProbeTests {
    let fm = FileManager.default

    private func makeProbe(
        stderrPath: String,
        stub: @escaping @Sendable (String, [String]) -> CommandOutput = idleStub
    ) -> ShipItProbe {
        ShipItProbe(
            bundleID: "com.anthropic.claudefordesktop",
            stderrPath: stderrPath,
            runner: RecordingCommandRunner(handler: stub)
        )
    }

    // MARK: - Liveness

    @Test
    func notRunningWhenPgrepFindsNothing() {
        // `pgrep` exits 1 on no match — a definitive "no", not an error to wait out.
        #expect(makeProbe(stderrPath: "/nonexistent").isRunning() == false)
    }

    @Test
    func runningWhenPgrepMatchesOurJobLabel() {
        let probe = makeProbe(stderrPath: "/nonexistent") { executable, _ in
            executable == CoreConstants.pgrepPath
                ? CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                : idleStub(executable, [])
        }
        #expect(probe.isRunning())
    }

    @Test
    func anUnknownProbeResultCountsAsRunning() {
        // Only exit 1 means "nothing matched". A usage error (2), a fatal error (3) or a
        // failure to spawn at all say nothing about the installer — and answering "gone" to
        // those is what relaunches profiles mid-install.
        for exitCode in [Int32(2), 3, 127] {
            let probe = makeProbe(stderrPath: "/nonexistent") { executable, _ in
                executable == CoreConstants.pgrepPath
                    ? CommandOutput(exitCode: exitCode, standardOutput: "", standardError: "pgrep: bad")
                    : idleStub(executable, [])
            }
            #expect(probe.isRunning(), "exit \(exitCode) is unknown, not 'gone'")
        }
    }

    @Test
    func aProbeThatCannotRunCountsAsRunning() {
        let probe = ShipItProbe(
            bundleID: "com.anthropic.claudefordesktop",
            stderrPath: "/nonexistent",
            runner: UnrunnableToolRunner()
        )
        #expect(probe.isRunning())
    }

    @Test
    func exitZeroCountsAsRunningEvenWithNothingCaptured() {
        // Exit 0 already means something matched. A lost capture must not downgrade that to
        // "gone" — during an apply that answer relaunches profiles into a live install.
        let probe = makeProbe(stderrPath: "/nonexistent") { executable, _ in
            executable == CoreConstants.pgrepPath
                ? CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                : idleStub(executable, [])
        }
        #expect(probe.liveness() == .runningPIDUnknown)
        #expect(probe.isRunning())
        #expect(probe.isConfirmedRunning())
    }

    @Test
    func aBrokenProbeBlocksAWaitButNotAGuard() {
        // The two readings of "can't tell" are deliberately opposite: a wait is paranoid
        // (it has a budget), a permanent guard fails open (it has none — refusing on an
        // unhealthy probe would disable every launch in the app forever).
        let probe = makeProbe(stderrPath: "/nonexistent") { executable, _ in
            executable == CoreConstants.pgrepPath
                ? CommandOutput(exitCode: 3, standardOutput: "", standardError: "pgrep: fatal")
                : idleStub(executable, [])
        }
        #expect(probe.liveness() == .unknown)
        #expect(probe.isRunning()) // wait: treat unknown as still installing
        #expect(!probe.isConfirmedRunning()) // guard: do not block on a guess
    }

    @Test
    func reportsThePIDWhenPgrepGivesOne() {
        let probe = makeProbe(stderrPath: "/nonexistent") { executable, _ in
            executable == CoreConstants.pgrepPath
                ? CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                : idleStub(executable, [])
        }
        #expect(probe.liveness() == .running(pid: 4242))
    }

    @Test
    func matchesOnBundleScopedJobLabel() {
        // Another app's updater runs the same Squirrel binary, so the pattern must carry
        // our bundle id — otherwise VS Code installing would read as Claude installing.
        let runner = RecordingCommandRunner(handler: idleStub)
        let probe = ShipItProbe(
            bundleID: "com.anthropic.claudefordesktop",
            stderrPath: "/nonexistent",
            runner: runner
        )
        _ = probe.isRunning()
        let arguments = runner.invocations(of: CoreConstants.pgrepPath).first?.arguments ?? []
        #expect(arguments.first == "-f")
        #expect(arguments.last?.contains("/ShipIt ") == true)
        #expect(arguments.last?.contains("com\\.anthropic\\.claudefordesktop\\.ShipIt") == true)
    }

    // MARK: - Failure reason

    @Test
    func failureReasonReadsOnlyWhatWasAppended() throws {
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let log = root.appendingPathComponent("ShipIt_stderr.log")
        // A failure from a previous attempt, days ago — this must never be reported as the
        // current one. ShipIt never rotates this file, so the stale tail is always there.
        try "2026-08-15 11:51:47.846 ShipIt[1:2] Too many attempts to install, aborting update\n"
            .write(to: log, atomically: true, encoding: .utf8)

        let probe = makeProbe(stderrPath: log.path)
        let offset = probe.stderrOffset()
        #expect(probe.failureReason(since: offset) == nil)

        try (String(contentsOf: log, encoding: .utf8)
            + "2026-08-19 13:48:55.843 ShipIt[3:4] Aborting update attempt because there are "
            + "2 running instances of the target app\n")
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(probe.failureReason(since: offset)?.contains("was running while ShipIt") == true)
    }

    @Test
    func failureReasonIsNilWithoutALog() {
        let probe = makeProbe(stderrPath: "/nonexistent/ShipIt_stderr.log")
        #expect(probe.stderrOffset() == 0)
        #expect(probe.failureReason(since: 0) == nil)
    }

    @Test
    func failureReasonTakesTheLastFailureInTheAppendedRange() throws {
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let log = root.appendingPathComponent("ShipIt_stderr.log")
        try ("2026-08-19 13:00:00.000 ShipIt[1:2] Beginning installation\n"
            + "2026-08-19 13:00:01.000 ShipIt[1:2] Installation error: disk full\n"
            + "2026-08-19 13:00:02.000 ShipIt[1:2] Too many attempts to install, aborting update\n")
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(makeProbe(stderrPath: log.path)
            .failureReason(since: 0) == "ShipIt gave up after repeated failed attempts")
    }

    // MARK: - Line classification

    @Test
    func classifiesTheInstanceRaceThatAPrematureRelaunchCauses() {
        let line = "ShipIt[10254:157650019] Aborting update attempt because there are "
            + "2 running instances of the target app"
        #expect(ShipItProbe.reason(inLine: line)?.contains("was running while ShipIt") == true)
        let cancelled = #"ShipIt[1:2] Installation cancelled: Error Domain=SQRLInstallerErrorDomain "#
            + #"Code=-9 "App Still Running Error""#
        #expect(ShipItProbe.reason(inLine: cancelled)?.contains("was running while ShipIt") == true)
    }

    @Test
    func passesThroughAnUnknownInstallationError() {
        let reason = ShipItProbe.reason(inLine: "ShipIt[1:2] Installation error: Failed to copy bundle")
        #expect(reason == "Failed to copy bundle")
    }

    @Test
    func condensesAVerboseNSErrorDump() throws {
        let dump = "ShipIt[1:2] Installation error: " + String(
            repeating: "UserInfo={NSFilePath=/x}; ",
            count: 40
        )
        let reason = try #require(ShipItProbe.reason(inLine: dump))
        #expect(reason.count <= 200)
        #expect(reason.hasSuffix("…"))
    }

    @Test
    func ordinaryProgressLinesAreNotFailures() {
        #expect(ShipItProbe.reason(inLine: "ShipIt[1:2] Beginning installation") == nil)
        #expect(ShipItProbe.reason(inLine: "ShipIt[1:2] Installation completed successfully") == nil)
    }
}

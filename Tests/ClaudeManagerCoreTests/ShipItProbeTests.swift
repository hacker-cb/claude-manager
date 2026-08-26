import Foundation
import Testing
@testable import ClaudeManagerCore

struct ShipItProbeTests {
    let fm = FileManager.default

    private func makeProbe(
        stderrPath _: String,
        stub: @escaping @Sendable (String, [String]) -> CommandOutput = idleStub
    ) -> ShipItProbe {
        ShipItProbe(
            bundleID: "com.anthropic.claudefordesktop",
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
            runner: runner
        )
        _ = probe.isRunning()
        let arguments = runner.invocations(of: CoreConstants.pgrepPath).first?.arguments ?? []
        #expect(arguments.first == "-f")
        #expect(arguments.last?.contains("/ShipIt ") == true)
        #expect(arguments.last?.contains("com\\.anthropic\\.claudefordesktop\\.ShipIt") == true)
    }
}

import Foundation

/// Whether Claude's own installer is running right now.
///
/// Everything this type used to do *around* that question went with the machinery that
/// needed it: the failure-reason log reader, the elapsed-time diagnostic, the wait that
/// watched a swap rather than a clock. All of it existed to survive an installer this app no
/// longer depends on.
///
/// Two callers still ask, and both are about not colliding with it: the installer refuses to
/// swap `/Applications/Claude.app` while ShipIt might be writing the same bundle, and the
/// residue sweep refuses to delete a staged bundle out from under it. They matter because
/// Squirrel is *disabled*, not absent — updating can be handed back at any time, and a job
/// armed before the switch outlives it.
public struct ShipItProbe {
    /// Bundle id of the app being updated (`com.anthropic.claudefordesktop`), which is also
    /// how ShipIt's own job is named on its argv.
    let bundleID: String
    let runner: CommandRunner

    public init(bundleID: String, runner: CommandRunner) {
        self.bundleID = bundleID
        self.runner = runner
    }

    /// Whether a ShipIt process for this bundle is alive — with **"can't tell" kept apart
    /// from "no"**, because the two callers need opposite answers to it.
    ///
    /// Matched on the executable name plus the job label ShipIt carries as its first
    /// argument (`…/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt …`), so another
    /// app's updater — VS Code and GitKraken ship the same Squirrel binary — never counts
    /// as ours.
    ///
    /// Only `pgrep`'s exit **1** means "nothing matched"; 2 is a usage error, 3 a fatal one,
    /// and a failure to spawn it has no exit code at all. Exit 0 means something *did*
    /// match, so it counts as running even when the captured output is unreadable — the
    /// exit status is the answer, the pid is only a bonus.
    public enum Liveness: Equatable, Sendable {
        /// Matched, and this is the process.
        case running(pid: Int32)
        /// Matched, but the pid could not be read back.
        case runningPIDUnknown
        /// `pgrep` said nothing matched.
        case gone
        /// The probe itself failed — this says nothing about the installer.
        case unknown
    }

    public func liveness() -> Liveness {
        let pattern = "/ShipIt " + PathUtils.regexEscaped(bundleID) + "\\.ShipIt"
        guard let output = try? runner.run(CoreConstants.pgrepPath, ["-f", pattern]) else {
            return .unknown // couldn't even run the probe
        }
        switch output.exitCode {
        case 0:
            // Exit 0 already means "at least one process matched"; a lost capture must not
            // downgrade that to "gone", which would relaunch profiles mid-install.
            guard let pid = output.trimmedOutput
                .split(whereSeparator: \.isWhitespace).first.flatMap({ Int32($0) })
            else { return .runningPIDUnknown }
            return .running(pid: pid)
        case 1: return .gone // pgrep reserves 1 for "no processes matched"
        default: return .unknown // usage/fatal error
        }
    }

    /// "Not known to be gone" — the reading a **wait** wants. Uncertainty resolves to
    /// *running* here because the costs are not symmetric: a wrong "gone" relaunches
    /// profiles into a live install and destroys it, while a wrong "running" only spends
    /// the caller's poll budget and ends in a message the user sees.
    public func isRunning() -> Bool {
        liveness() != .gone
    }

    /// "Known to be running" — the reading a **block** wants. A guard that refuses on
    /// uncertainty refuses forever, since nothing resolves an unhealthy probe: with `pgrep`
    /// broken, every Open, Restart and deep link in the app would be dead with no budget to
    /// run out. So an unknown fails *open* here, exactly opposite to ``isRunning()``.
    public func isConfirmedRunning() -> Bool {
        switch liveness() {
        case .running, .runningPIDUnknown: true
        case .gone, .unknown: false
        }
    }
}

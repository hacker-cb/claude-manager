import Foundation

/// Doctor's staged-update rows: whether an update is waiting, what the installer is doing,
/// and how close Claude is to restarting the default profile by itself. Split from
/// `Doctor.swift` because they share one subject — ShipIt's job, its process and its log —
/// and none of it overlaps the launcher, signature and orphan checks there.
extension Doctor {
    /// A warning the **app** appends when a staged update has been waiting long enough that
    /// Claude will soon restart the default profile by itself. Like the residency warning
    /// below it can't live in `run()`: the first-sighting date is app-layer state (Core has
    /// nowhere to record it, and nothing on disk survives a re-arm — `ShipItState.plist`'s
    /// mtime is rewritten on every retry).
    ///
    /// Worded as an estimate on purpose; see `StagedUpdateDeadline` for why it can only ever
    /// be one. `nil` until the restart is within `StagedUpdateDeadline.warningLead`, so the
    /// vast majority of waits — which end long before the window — say nothing at all.
    public static func stagedUpdateDeadlineDiagnostic(
        stagedVersion: String,
        deadline: StagedUpdateDeadline,
        now: Date = Date()
    ) -> Diagnostic? {
        guard deadline.isApproaching(asOf: now, lead: StagedUpdateDeadline.warningLead) else { return nil }
        let waitedHours = Int(deadline.waited(asOf: now) / 3600)
        let remaining = deadline.remaining(asOf: now)
        let when = remaining <= 0
            ? "at any time now"
            : "in about \(max(1, Int(remaining / 3600))) h"
        return Diagnostic(
            severity: .warning,
            // Name the subject: "restart it" reads as restarting the *update*, and the thing
            // that actually restarts is the default profile.
            title: "Claude \(stagedVersion) has been waiting \(waitedHours) h — "
                + "the default profile may restart itself \(when)",
            detail: "Claude restarts the default profile by itself once an update has been pending "
                + "for about \(Int(deadline.enforcementHours)) h, and it picks a moment you're away. "
                + "Use “Apply to all profiles” to choose the moment instead."
        )
    }

    /// A warning when a Claude update is staged but not applied — ShipIt can't swap
    /// `/Applications/Claude.app` while any instance runs, the "Update didn't complete"
    /// case. Distinct from the per-launcher version-skew warning (there the swap happened).
    /// Module-internal rather than `private` only because `run()` lives in `Doctor.swift`
    /// and Swift's `private` is file-scoped — the encapsulation is the file split, not the
    /// keyword. Nothing outside `Doctor` calls it.
    func stagedUpdateDiagnostics() -> [Diagnostic] {
        guard let realClaude else { return [] }
        let staged = StagedUpdateProbe(
            realClaude: realClaude,
            shipItStatePath: configuration.shipItStatePath,
            fileManager: fileManager
        ).probe()
        let installer = installerDiagnostics(realClaude: realClaude, staged: staged)
        guard let staged else { return installer }
        // Count only real-Claude instances (default + clones exec the real binary) — not
        // Claude Manager's own process, whose path also contains "Claude".
        let running = processProbe.allClaudeMains()
            .count(where: { $0.isRealClaudeBinary(realClaude) })

        let blockers = running == 0
            ? ""
            : " — \(running) running instance\(running == 1 ? "" : "s") block the swap"
        return [Diagnostic(
            severity: .warning,
            title: "Claude \(staged.stagedVersion) staged but not applied\(blockers)",
            detail: "Use “Apply to all profiles” to quit every profile, swap, and reopen"
        )] + installer
    }

    /// What Claude's own installer is doing, and how its last attempt ended.
    ///
    /// Both rows exist because this failure is otherwise **completely silent**: ShipIt waits
    /// for zero instances indefinitely, writing only to its own log, so a machine can sit for
    /// days with an update that will never install and no surface saying so. The user's first
    /// hint was the default profile restarting itself at 4 am.
    private func installerDiagnostics(realClaude: RealClaude, staged: StagedUpdate?) -> [Diagnostic] {
        let probe = ShipItProbe(
            bundleID: realClaude.bundleIdentifier(fileManager: fileManager)
                ?? CoreConstants.realClaudeBundleIDs[0],
            stderrPath: CoreConstants.shipItStderrPath(forStatePath: configuration.shipItStatePath),
            // The caller's runner, never a fresh `SystemCommandRunner` — same reason the
            // init refuses to default `bundle` and `codeSigner`.
            runner: processProbe.runner,
            fileManager: fileManager
        )
        var rows: [Diagnostic] = []

        if let age = probe.runningFor(), age >= CoreConstants.shipItStuckSeconds {
            let minutes = Int(age / 60)
            rows.append(Diagnostic(
                severity: .warning,
                title: "Claude's installer has been waiting \(minutes) min",
                detail: "ShipIt can't swap Claude.app while any profile runs, and it waits "
                    + "indefinitely. Use “Apply to all profiles”."
            ))
        }

        // Only worth saying while something is still armed — there is then a failure the user
        // is actually living with. Read over the whole log (no offset), so word it as the last
        // recorded attempt rather than as something happening now.
        if staged != nil, let reason = probe.failureReason(since: 0) {
            rows.append(Diagnostic(
                severity: .warning,
                title: "The last install attempt didn't complete",
                detail: "ShipIt reported: \(reason)."
            ))
        }
        return rows
    }
}

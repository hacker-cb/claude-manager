import Foundation

/// Coordinated apply of a staged Claude update across every profile. ShipIt can only swap
/// `/Applications/Claude.app` when **zero** `com.anthropic.claudefordesktop` instances run
/// (Gate 1 blocks until termination; Gate 2 waits out the swap itself), so any open clone
/// stalls it. This quits the whole set, waits for the swap, and relaunches what was open.
///
/// **Gate 2 watches ShipIt's process, never a clock.** The swap normally takes 3–5 s, but
/// the same bundle has taken 28 s and 57 s under disk contention, so no timeout can tell
/// "still copying" from "gave up". Getting that wrong is destructive rather than merely
/// unhelpful: relaunching mid-install makes ShipIt's own instance re-check fail
/// (`App Still Running Error`), killing an install that was going through. So while the swap
/// is *pending*, nothing is relaunched — a large budget as a backstop, and a deliberate
/// refusal to relaunch while it is still installing.
///
/// One bounded exception, once the bundle is already in place: success drains until ShipIt
/// exits, but only for `swapDrainPolls`. Past that the swap has demonstrably landed — the
/// on-disk version changed — so an installer still lingering over its cleanup is no reason to
/// keep the user's profiles closed indefinitely.
public extension ProfileStore {
    struct ApplyStagedUpdateResult: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The on-disk version reached the staged version.
            case applied(from: String?, to: String)
            /// No armed staged update at apply time (re-read of `ShipItState`).
            case noStagedUpdate
            /// Some instance would not exit gracefully — aborted before the swap window so
            /// nothing is force-killed mid-conversation. A profile with a *working* session
            /// lands here: Claude vetoes its own quit (`vetoed by before-quit interceptor`)
            /// and shows "Claude is still working", which is exactly the protection we want.
            case instancesStillRunning([String])
            /// ShipIt finished (or never picked the job up) and the version never changed.
            /// `reason` is what ShipIt logged for *this* attempt, when it logged anything.
            case swapDidNotComplete(stagedVersion: String, reason: String?)
            /// The safety budget elapsed while ShipIt was still installing. Profiles are
            /// deliberately left closed — relaunching here is what destroys the install.
            case swapStillInstalling(stagedVersion: String)
        }

        public let outcome: Outcome
        /// Profiles reopened afterward (profile display names, plus "default profile").
        public let relaunched: [String]
    }

    /// Quit every running profile (clones + default), wait for ShipIt to swap in the staged
    /// bundle, then relaunch the previously-open set. Graceful stops only (never SIGKILL an
    /// active conversation); if an instance won't exit, aborts **before** the swap window
    /// and reports it rather than risking a Gate 2 failure or data loss. Relaunches the
    /// profiles that did stop on abort and on a completed-but-failed swap, so the user is
    /// never left with fewer profiles than they had — the one exception being an install
    /// still in flight, where relaunching is the harm.
    ///
    /// `swapMaxPolls` is a **backstop, not an expectation**: at the default cadence it is
    /// ten minutes, two orders of magnitude past a normal swap. `shipItGracePolls` bounds
    /// only the wait for ShipIt to *appear*, so a machine with no armed installer fails in
    /// seconds instead of parking on the full budget.
    func applyStagedUpdateToAll(
        stopPollInterval: TimeInterval = 0.5,
        stopMaxPolls: Int = 20,
        swapPollInterval: TimeInterval = 1.0,
        swapMaxPolls: Int = 600,
        shipItGracePolls: Int = 5,
        swapDrainPolls: Int = 30
    ) async -> ApplyStagedUpdateResult {
        // Re-read at apply time — the staged bundle may have been GC'd or already applied.
        guard let staged = stagedUpdate() else {
            return ApplyStagedUpdateResult(outcome: .noStagedUpdate, relaunched: [])
        }

        let probe = shipItProbe()
        // Anchor the log *before* anything can write to it, so a failure we report is this
        // attempt's and not one from days ago sitting in the same never-rotated file.
        let logOffset = probe.stderrOffset()

        // Snapshot what's open, so we can restore exactly that set afterward.
        let runningClones = list().filter(\.isRunning).map(\.profile)
        let defaultWasRunning = runningDefaultPID() != nil

        // Graceful stop of every profile.
        for clone in runningClones {
            _ = await stop(clone, force: false, pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }
        if defaultWasRunning {
            _ = await stopDefault(pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }

        // ShipIt gates on *zero* real-Claude instances — if any won't exit, abort before
        // the swap but still reopen whatever *did* stop, so the working set isn't lost.
        guard await pollUntilNoBlockingInstances(interval: stopPollInterval, maxPolls: stopMaxPolls) else {
            // Capture the blockers *before* relaunching — otherwise a profile that did quit
            // and we reopen here can reappear in `ps` and be misreported as one that
            // "wouldn't quit gracefully", inflating the count and blaming a healthy profile.
            let stillRunning = blockingInstanceNames()
            let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
            return ApplyStagedUpdateResult(
                outcome: .instancesStillRunning(stillRunning), relaunched: relaunched
            )
        }

        // ShipIt now swaps the app; wait it out by watching the installer, not the clock.
        let wait = await awaitSwap(SwapWatch(
            stagedVersion: staged.stagedVersion,
            probe: probe,
            interval: swapPollInterval,
            maxPolls: swapMaxPolls,
            gracePolls: shipItGracePolls,
            drainPolls: swapDrainPolls
        ))

        // Relaunching while ShipIt is mid-install is precisely what aborts it, so that one
        // outcome leaves the set closed and says so. Every other path restores it.
        guard wait != .stillInstalling else {
            return ApplyStagedUpdateResult(
                outcome: .swapStillInstalling(stagedVersion: staged.stagedVersion), relaunched: []
            )
        }
        let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)

        let outcome: ApplyStagedUpdateResult.Outcome = switch wait {
        case .swapped:
            .applied(from: staged.installedVersion, to: staged.stagedVersion)
        default:
            .swapDidNotComplete(
                stagedVersion: staged.stagedVersion,
                reason: probe.failureReason(since: logOffset)
            )
        }
        return ApplyStagedUpdateResult(outcome: outcome, relaunched: relaunched)
    }

    /// Whether Claude's own installer is **known** to be working on
    /// `/Applications/Claude.app` right now.
    ///
    /// Exposed because an install outlives *our* apply: `swapStillInstalling` hands control
    /// back with ShipIt still copying, and from that moment nothing in the app's own state
    /// says a swap is in flight. Launching any Claude then makes ShipIt abort — so the
    /// launch guards ask this, a fact about the machine, rather than a flag about us.
    ///
    /// Deliberately the *confirmed* reading, not the one `awaitSwap` waits on: this answer
    /// gates every launch in the app, with no budget to run out, so an unhealthy probe
    /// answering "maybe" would disable Open, Restart and deep links indefinitely. A wait can
    /// afford to be paranoid; a permanent guard cannot.
    func isClaudeInstallerRunning() -> Bool {
        shipItProbe().isConfirmedRunning()
    }

    // MARK: - Internals

    /// How a Gate 2 wait ended. Distinct from the public outcome because "still installing"
    /// governs *relaunch behaviour* before it ever becomes a message.
    private enum SwapWait {
        /// The on-disk version reached (or passed) the staged one.
        case swapped
        /// ShipIt is gone and the version never moved.
        case didNotComplete
        /// The budget elapsed with ShipIt still working.
        case stillInstalling
    }

    /// Wait for the swap by watching ShipIt: while it lives the install is in flight and
    /// nothing may be relaunched; once it exits, the on-disk version is the verdict.
    ///
    /// The grace window covers the gap where ShipIt has been asked to install but has not
    /// been observed yet. After ShipIt has been seen once, its disappearance is conclusive —
    /// either the version moved or the attempt failed.
    ///
    /// **A new version on disk is not the end of ShipIt's work.** It swaps the bundle, then
    /// cleans up and may hand off to a fresh ShipIt (measured: ~280 ms between `Moving
    /// bundle` and `ShipIt quitting`). Returning at the version change alone would relaunch
    /// inside that tail, breaking the very invariant this gate exists to hold — so success
    /// drains until the installer is actually gone. `drainPolls` bounds that drain, because
    /// the swap has already happened by then: an installer that lingers is no reason to keep
    /// the user's profiles closed indefinitely.
    private func awaitSwap(_ watch: SwapWatch) async -> SwapWait {
        let duration = Duration.seconds(max(0, watch.interval))
        guard await waitForBundle(watch, step: duration) else {
            // Nothing landed. Only a *confirmed* absence makes this a failure; anything else
            // is an install we should not walk over.
            return watch.probe.isRunning() ? .stillInstalling : .didNotComplete
        }
        // The bundle is in place. Drain ShipIt's tail on its **own** budget — folding it
        // into the loop above meant a swap first seen on the final poll skipped the drain
        // entirely and relaunched into a live installer, which is the original bug again.
        for _ in 0 ..< max(0, watch.drainPolls) {
            if !watch.probe.isRunning() { return .swapped }
            guard await sleep(for: duration) else { break }
        }
        return .swapped
    }

    /// Poll until the on-disk version reaches the staged one, or the attempt is provably
    /// dead. Returns whether the bundle landed.
    ///
    /// The version is re-read **after** an observed disappearance: each pass reads the
    /// version before running `pgrep`, so an installer that swaps and exits between those
    /// two reads would otherwise be recorded as a failure for an update that succeeded.
    private func waitForBundle(_ watch: SwapWatch, step: Duration) async -> Bool {
        var sawInstaller = false
        let maxPolls = max(0, watch.maxPolls)
        for poll in 0 ... maxPolls {
            if isVersionAtLeast(watch.stagedVersion) { return true }
            let installing = watch.probe.isRunning()
            if installing {
                sawInstaller = true
            } else if sawInstaller || poll >= max(0, watch.gracePolls) {
                return isVersionAtLeast(watch.stagedVersion) // it may have finished just now
            }
            if poll == maxPolls { break }
            guard await sleep(for: step) else { break } // cancelled — stop waiting
        }
        return isVersionAtLeast(watch.stagedVersion)
    }

    /// Suspend for one poll, reporting whether the wait completed (`false` when cancelled).
    private func sleep(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    /// What one Gate 2 wait is watching, and the three limits that bound it — grouped so the
    /// cadence, the backstop and the drain travel together instead of as a parameter list
    /// whose order is easy to transpose at the call site.
    private struct SwapWatch {
        let stagedVersion: String
        let probe: ShipItProbe
        let interval: TimeInterval
        /// Backstop for the whole wait, not an expectation of how long a swap takes.
        let maxPolls: Int
        /// How long to wait for ShipIt to *appear* before calling the attempt dead.
        let gracePolls: Int
        /// How long to wait for ShipIt to *leave* after the version already changed.
        let drainPolls: Int
    }

    /// ShipIt for the app this store manages. The bundle id is resolved the same way
    /// `ProfileStoreConfiguration.makeDefault` resolves the one behind `shipItStatePath`, so
    /// a legacy-id install is watched under the same id whose state file we read.
    private func shipItProbe() -> ShipItProbe {
        ShipItProbe(
            bundleID: realClaude.bundleIdentifier(fileManager: fileManager)
                ?? CoreConstants.realClaudeBundleIDs[0],
            stderrPath: CoreConstants.shipItStderrPath(forStatePath: configuration.shipItStatePath),
            runner: runner,
            fileManager: fileManager
        )
    }

    /// True once the on-disk version is at least `version` — a `>=` order (not exact
    /// equality), so a swap that lands `version` or anything newer counts as applied.
    private func isVersionAtLeast(_ version: String) -> Bool {
        guard let current = realClaude.version(fileManager: fileManager) else { return false }
        return current == version || VersionOrder.isNewer(current, than: version)
    }
}

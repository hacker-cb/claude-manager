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
/// (`App Still Running Error`), killing an install that was going through. So profiles are
/// relaunched only once ShipIt is **gone** — with a large budget as a backstop, and a
/// deliberate refusal to relaunch while it is still installing.
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

    /// Whether Claude's own installer is working on `/Applications/Claude.app` right now.
    ///
    /// Exposed because an install outlives *our* apply: `swapStillInstalling` hands control
    /// back with ShipIt still copying, and from that moment nothing in the app's own state
    /// says a swap is in flight. Launching any Claude then makes ShipIt abort — so the
    /// launch guards ask this, a fact about the machine, rather than a flag about us.
    /// Answers `true` when the probe cannot tell (see `ShipItProbe.isRunning`).
    func isClaudeInstallerRunning() -> Bool {
        shipItProbe().isRunning()
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
        var sawInstaller = false
        var swapped = false
        var draining = 0
        let duration = Duration.seconds(max(0, watch.interval))
        let maxPolls = max(0, watch.maxPolls)
        for poll in 0 ... maxPolls {
            swapped = swapped || isVersionAtLeast(watch.stagedVersion)
            let installing = watch.probe.isRunning()
            if installing { sawInstaller = true }

            if swapped {
                // The bundle is in place; wait out ShipIt's tail, but not forever.
                if !installing { return .swapped }
                draining += 1
                if draining > max(0, watch.drainPolls) { return .swapped }
            } else if !installing, sawInstaller || poll >= watch.gracePolls {
                return .didNotComplete
            }

            if poll == maxPolls { break }
            do {
                try await Task.sleep(for: duration)
            } catch {
                break // cancelled — stop waiting
            }
        }
        if swapped || isVersionAtLeast(watch.stagedVersion) { return .swapped }
        return watch.probe.isRunning() ? .stillInstalling : .didNotComplete
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

    /// Live instances of the **real Claude binary** — the default and clones both `exec` it,
    /// so this is exactly the set ShipIt gates on. Excludes Claude Manager's own process,
    /// whose path also contains "Claude" and would otherwise keep the gate from ever passing.
    private func blockingInstances() -> [ClaudeInstance] {
        runningInstances().filter { $0.isRealClaudeBinary(realClaude) }
    }

    /// Friendly names for the still-running blockers — a clone's display name where the
    /// user-data dir maps to a known launcher, else "default profile".
    private func blockingInstanceNames() -> [String] {
        let displayByProfile = Dictionary(
            list().map { ($0.profile.profilePath, $0.profile.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return blockingInstances().map { instance in
            guard let profile = instance.profilePath else { return "default profile" }
            return displayByProfile[profile] ?? profile
        }
    }

    /// Relaunch each snapshotted profile that is currently **down**. Skipping still-running
    /// profiles matters most for the default: reopening a live default with `open -n` would
    /// spawn a duplicate on its user-data-dir and corrupt LevelDB (ShipIt itself often
    /// relaunches the default after a swap). A still-running clone is a launcher-dedup no-op
    /// but is skipped for symmetry.
    private func relaunchSnapshot(clones: [Profile], defaultWasRunning: Bool) -> [String] {
        var relaunched: [String] = []
        if defaultWasRunning, runningDefaultPID() == nil, relaunchDefaultProfile() {
            relaunched.append("default profile")
        }
        for clone in clones where runningPID(for: clone) == nil && (try? open(clone)) != nil {
            relaunched.append(clone.displayName)
        }
        return relaunched
    }

    /// Reopen the default profile, returning whether it launched. A plain `open` (which
    /// de-dups) is safe unless a **non-default** real-Claude instance is running: if nothing
    /// runs it launches the default, and if only the default itself is up — e.g. ShipIt
    /// relaunched it in the race window between `relaunchSnapshot`'s `runningDefaultPID()`
    /// guard and here — it *activates* that instance rather than forcing a duplicate onto its
    /// user-data-dir (LevelDB corruption). `-n` is required only when a clone or an external
    /// `--user-data-dir` instance is running, since there a plain `open` would merely activate
    /// *that* instance (all share the one bundle id) instead of starting the default. The
    /// default's own instance carries no `--user-data-dir`, so it has a `nil` profile path.
    private func relaunchDefaultProfile() -> Bool {
        let nonDefaultRunning = blockingInstances().contains { $0.profilePath != nil }
        if nonDefaultRunning {
            return (try? openReal()) != nil
        }
        return (try? runner.runChecked(CoreConstants.openPath, [realClaude.appURL.path])) != nil
    }

    private func pollUntilNoBlockingInstances(interval: TimeInterval, maxPolls: Int) async -> Bool {
        await poll(interval: interval, maxPolls: maxPolls) { blockingInstances().isEmpty }
    }

    /// True once the on-disk version is at least `version` — a `>=` order (not exact
    /// equality), so a swap that lands `version` or anything newer counts as applied.
    private func isVersionAtLeast(_ version: String) -> Bool {
        guard let current = realClaude.version(fileManager: fileManager) else { return false }
        return current == version || VersionOrder.isNewer(current, than: version)
    }
}

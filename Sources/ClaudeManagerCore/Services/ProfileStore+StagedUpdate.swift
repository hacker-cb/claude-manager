import Foundation

/// Coordinated apply of a staged Claude update across every account. ShipIt can only swap
/// `/Applications/Claude.app` when **zero** `com.anthropic.claudefordesktop` instances run
/// (Gate 1 blocks until termination; Gate 2 aborts if any instance is live during the ~4 s
/// swap), so any open clone stalls it. This quits the whole set, waits for the swap, and
/// relaunches what was open.
public extension ProfileStore {
    struct ApplyStagedUpdateResult: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The on-disk version reached the staged version.
            case applied(from: String?, to: String)
            /// No armed staged update at apply time (re-read of `ShipItState`).
            case noStagedUpdate
            /// Some instance would not exit gracefully — aborted before the swap window so
            /// nothing is force-killed mid-conversation.
            case instancesStillRunning([String])
            /// All instances quit, but the version never reached the staged one in the
            /// timeout — likely no armed ShipIt job (needs a "Restart to update" to arm),
            /// not a hang.
            case swapTimedOut(stagedVersion: String)
        }

        public let outcome: Outcome
        /// Accounts reopened afterward (profile display names, plus "default account").
        public let relaunched: [String]
    }

    /// Quit every running account (clones + default), wait for ShipIt to swap in the staged
    /// bundle, then relaunch the previously-open set. Graceful stops only (never SIGKILL an
    /// active conversation); if an instance won't exit, aborts **before** the swap window
    /// and reports it rather than risking a Gate 2 failure or data loss. Relaunches the
    /// accounts that did stop even on abort or swap-timeout, so the user is never left with
    /// fewer accounts than they had.
    func applyStagedUpdateToAll(
        stopPollInterval: TimeInterval = 0.5,
        stopMaxPolls: Int = 20,
        swapPollInterval: TimeInterval = 1.0,
        swapMaxPolls: Int = 30
    ) async -> ApplyStagedUpdateResult {
        // Re-read at apply time — the staged bundle may have been GC'd or already applied.
        guard let staged = stagedUpdate() else {
            return ApplyStagedUpdateResult(outcome: .noStagedUpdate, relaunched: [])
        }

        // Snapshot what's open, so we can restore exactly that set afterward.
        let runningClones = list().filter(\.isRunning).map(\.profile)
        let defaultWasRunning = runningDefaultPID() != nil

        // Graceful stop of every account.
        for clone in runningClones {
            _ = await stop(clone, force: false, pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }
        if defaultWasRunning {
            _ = await stopDefault(pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }

        // ShipIt gates on *zero* real-Claude instances — if any won't exit, abort before
        // the swap but still reopen whatever *did* stop, so the working set isn't lost.
        guard await pollUntilNoBlockingInstances(interval: stopPollInterval, maxPolls: stopMaxPolls) else {
            // Capture the blockers *before* relaunching — otherwise an account that did quit
            // and we reopen here can reappear in `ps` and be misreported as one that
            // "wouldn't quit gracefully", inflating the count and blaming a healthy account.
            let stillRunning = blockingInstanceNames()
            let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
            return ApplyStagedUpdateResult(
                outcome: .instancesStillRunning(stillRunning), relaunched: relaunched
            )
        }

        // ShipIt now swaps the app; wait for the on-disk version to reach the staged one.
        let swapped = await pollUntilVersionAtLeast(
            staged.stagedVersion, interval: swapPollInterval, maxPolls: swapMaxPolls
        )

        // Relaunch the snapshot regardless of the swap outcome — never leave nothing open.
        let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)

        let outcome: ApplyStagedUpdateResult.Outcome = swapped
            ? .applied(from: staged.installedVersion, to: staged.stagedVersion)
            : .swapTimedOut(stagedVersion: staged.stagedVersion)
        return ApplyStagedUpdateResult(outcome: outcome, relaunched: relaunched)
    }

    // MARK: - Internals

    /// Live instances of the **real Claude binary** — the default and clones both `exec` it,
    /// so this is exactly the set ShipIt gates on. Excludes Claude Manager's own process,
    /// whose path also contains "Claude" and would otherwise keep the gate from ever passing.
    private func blockingInstances() -> [ClaudeInstance] {
        runningInstances().filter { $0.isRealClaudeBinary(realClaude) }
    }

    /// Friendly names for the still-running blockers — a clone's display name where the
    /// user-data dir maps to a known launcher, else "default account".
    private func blockingInstanceNames() -> [String] {
        let displayByProfile = Dictionary(
            list().map { ($0.profile.profilePath, $0.profile.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return blockingInstances().map { instance in
            guard let profile = instance.profilePath else { return "default account" }
            return displayByProfile[profile] ?? profile
        }
    }

    /// Relaunch each snapshotted account that is currently **down**. Skipping still-running
    /// accounts matters most for the default: reopening a live default with `open -n` would
    /// spawn a duplicate on its user-data-dir and corrupt LevelDB (ShipIt itself often
    /// relaunches the default after a swap). A still-running clone is a launcher-dedup no-op
    /// but is skipped for symmetry.
    private func relaunchSnapshot(clones: [Profile], defaultWasRunning: Bool) -> [String] {
        var relaunched: [String] = []
        if defaultWasRunning, runningDefaultPID() == nil, relaunchDefaultAccount() {
            relaunched.append("default account")
        }
        for clone in clones where runningPID(for: clone) == nil && (try? open(clone)) != nil {
            relaunched.append(clone.displayName)
        }
        return relaunched
    }

    /// Reopen the default account, returning whether it launched. A plain `open` (which
    /// de-dups) is safe unless a **non-default** real-Claude instance is running: if nothing
    /// runs it launches the default, and if only the default itself is up — e.g. ShipIt
    /// relaunched it in the race window between `relaunchSnapshot`'s `runningDefaultPID()`
    /// guard and here — it *activates* that instance rather than forcing a duplicate onto its
    /// user-data-dir (LevelDB corruption). `-n` is required only when a clone or an external
    /// `--user-data-dir` instance is running, since there a plain `open` would merely activate
    /// *that* instance (all share the one bundle id) instead of starting the default. The
    /// default's own instance carries no `--user-data-dir`, so it has a `nil` profile path.
    private func relaunchDefaultAccount() -> Bool {
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
    private func pollUntilVersionAtLeast(
        _ version: String,
        interval: TimeInterval,
        maxPolls: Int
    ) async -> Bool {
        await poll(interval: interval, maxPolls: maxPolls) {
            guard let current = realClaude.version(fileManager: fileManager) else { return false }
            return current == version || VersionOrder.isNewer(current, than: version)
        }
    }
}

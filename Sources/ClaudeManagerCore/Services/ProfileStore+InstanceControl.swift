import Foundation

/// Stopping every Claude instance and putting the same set back afterwards.
///
/// `internal`, not `public`. `relaunchDefaultProfile` in particular is safe only from inside
/// `relaunchSnapshot`, which checks the default is actually down first: called directly while
/// the default is up *and* a clone is running, it takes the `open -n` branch and starts a
/// second instance on the same user-data dir — the LevelDB corruption `openReal` warns about.
/// That contract is not readable from the signature, so the type does not offer it outside
/// this module.
///
/// Lifted out of the staged-update path because it was never really about ShipIt: replacing
/// `/Applications/Claude.app` requires that nothing is running out of it, whoever is doing
/// the replacing. Squirrel's installer gated on the same set for the same reason, and when
/// that path goes away this machinery stays.
extension ProfileStore {
    /// Live instances of the **real Claude binary** — the default and clones both `exec` it,
    /// so this is exactly the set ShipIt gates on. Excludes Claude Manager's own process,
    /// whose path also contains "Claude" and would otherwise keep the gate from ever passing.
    func blockingInstances() -> [ClaudeInstance] {
        runningInstances().filter { $0.isRealClaudeBinary(realClaude) }
    }

    /// Live real-Claude instances, or **nil when the process list could not be read**.
    ///
    /// The distinction only matters to callers about to do something irreversible; see
    /// ``ProcessProbe/claudeMainsIfReadable()``.
    func blockingInstancesIfReadable() -> [ClaudeInstance]? {
        processProbe.claudeMainsIfReadable()?.filter { $0.isRealClaudeBinary(realClaude) }
    }

    /// Friendly names for the still-running blockers — a clone's display name where the
    /// user-data dir maps to a known launcher, else "default profile".
    func blockingInstanceNames() -> [String] {
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
    func relaunchSnapshot(clones: [Profile], defaultWasRunning: Bool) -> [String] {
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
    func relaunchDefaultProfile() -> Bool {
        let nonDefaultRunning = blockingInstances().contains { $0.profilePath != nil }
        if nonDefaultRunning {
            return (try? openReal()) != nil
        }
        return (try? runner.runChecked(CoreConstants.openPath, [realClaude.appURL.path])) != nil
    }

    func pollUntilNoBlockingInstances(interval: TimeInterval, maxPolls: Int) async -> Bool {
        await poll(interval: interval, maxPolls: maxPolls) { blockingInstances().isEmpty }
    }
}

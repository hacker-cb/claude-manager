import Foundation

/// Coordinated apply of a staged Claude update across every account. ShipIt can only swap
/// `/Applications/Claude.app` when **zero** `com.anthropic.claudefordesktop` instances run
/// (Gate 1 blocks until termination; Gate 2 aborts if any instance is live during the ~4 s
/// swap), so any open clone stalls it. This quits the whole set, waits for the swap, and
/// relaunches what was open.
public extension ProfileStore {
    struct ApplyStagedUpdateResult: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The on-disk version flipped to the staged version.
            case applied(from: String?, to: String)
            /// No armed staged update at apply time (re-read of `ShipItState`).
            case noStagedUpdate
            /// Some instance would not exit gracefully — aborted before the swap window so
            /// nothing is force-killed mid-conversation.
            case instancesStillRunning([String])
            /// All instances quit, but the version never flipped in the timeout — likely no
            /// armed ShipIt job (needs a "Restart to update" to arm), not a hang.
            case swapTimedOut(stagedVersion: String)
        }

        public let outcome: Outcome
        /// Accounts reopened afterward (profile display names, plus "default").
        public let relaunched: [String]
    }

    /// Quit every running account (clones + default), wait for ShipIt to swap in the staged
    /// bundle, then relaunch the previously-open set. Graceful stops only (never SIGKILL an
    /// active conversation); if an instance won't exit, aborts **before** the swap window
    /// and reports it rather than risking a Gate 2 failure or data loss. Relaunches the
    /// snapshot even when the swap times out, so the user is never left with nothing open.
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

        // ShipIt gates on *zero* instances — if any won't exit, abort before the swap and
        // reopen nothing was closed for (the stops already returned; nothing to restore).
        guard await pollUntilNoInstances(interval: stopPollInterval, maxPolls: stopMaxPolls) else {
            let stillUp = runningInstances().map { $0.profilePath ?? "default account" }
            return ApplyStagedUpdateResult(outcome: .instancesStillRunning(stillUp), relaunched: [])
        }

        // ShipIt now swaps the app; wait for the on-disk version to flip.
        let swapped = await pollUntilVersion(
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

    private func relaunchSnapshot(clones: [Profile], defaultWasRunning: Bool) -> [String] {
        var relaunched: [String] = []
        if defaultWasRunning, (try? openReal()) != nil {
            relaunched.append("default account")
        }
        for clone in clones where (try? open(clone)) != nil {
            relaunched.append(clone.displayName)
        }
        return relaunched
    }

    private func pollUntilNoInstances(interval: TimeInterval, maxPolls: Int) async -> Bool {
        await poll(interval: interval, maxPolls: maxPolls) { runningInstances().isEmpty }
    }

    private func pollUntilVersion(_ version: String, interval: TimeInterval, maxPolls: Int) async -> Bool {
        await poll(interval: interval, maxPolls: maxPolls) {
            realClaude.version(fileManager: fileManager) == version
        }
    }

    /// Poll `condition` up to `maxPolls` times, suspending `interval` between checks (never
    /// blocking a thread). Returns true as soon as it holds; a cancelled sleep stops early.
    private func poll(interval: TimeInterval, maxPolls: Int, _ condition: () -> Bool) async -> Bool {
        if condition() { return true }
        let duration = Duration.seconds(max(0, interval))
        for _ in 0 ..< maxPolls {
            do {
                try await Task.sleep(for: duration)
            } catch {
                break
            }
            if condition() { return true }
        }
        return condition()
    }
}

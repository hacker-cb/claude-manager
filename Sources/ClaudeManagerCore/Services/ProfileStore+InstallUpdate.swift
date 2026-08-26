import Foundation

/// What happened when a verified build was installed.
public struct InstallUpdateResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The bundle was replaced. Carries what was there before, when it could be read.
        case installed(from: String?, to: String)
        /// Some Claude instance refused to quit, so nothing was touched. Names the profiles
        /// still up — a profile with a live session declines `SIGTERM` on purpose, and
        /// saying which one is the difference between an error and an explanation.
        case instancesStillRunning([String])
        /// The swap itself failed. `/Applications/Claude.app` is untouched.
        case swapFailed(reason: String)
    }

    public let outcome: Outcome
    /// Profiles reopened afterwards — the same set that was closed, whatever the outcome.
    public let relaunched: [String]

    public init(outcome: Outcome, relaunched: [String]) {
        self.outcome = outcome
        self.relaunched = relaunched
    }
}

public extension ProfileStore {
    /// Close every Claude instance, swap in the verified bundle, and reopen what was closed.
    ///
    /// **Why everything has to close.** `/Applications/Claude.app` is shared: the default
    /// profile and every clone `exec` the same binary. Replacing it under a running Electron
    /// app leaves processes holding a bundle that no longer exists at that path, and Claude
    /// loads resources lazily — so the failure surfaces minutes later as something inexplicable
    /// rather than at the moment of the swap. This is not a leftover of Squirrel's design;
    /// Squirrel gated on the same thing for the same reason.
    ///
    /// **The swap is a rename.** `replaceItemAt` is atomic within a volume, and the caller is
    /// required to have unpacked onto the same one, so there is no window where the path holds
    /// half a bundle. A failure leaves the installed app exactly as it was.
    ///
    /// A profile that refuses to quit stops the whole thing before anything is touched.
    /// That is deliberate: Claude vetoes its own termination while a session is working, and
    /// "your update is waiting on this profile" is a far better outcome than taking the
    /// bundle out from under it.
    func installUpdate(
        _ verified: VerifiedUpdate,
        stopPollInterval: TimeInterval = 0.5,
        stopMaxPolls: Int = 20
    ) async -> InstallUpdateResult {
        let previousVersion = realClaude.version(fileManager: fileManager)
        CoreLog.update.info(
            """
            install: \(previousVersion ?? "unknown", privacy: .public) \
            → \(verified.version, privacy: .public)
            """
        )

        // Snapshot what is open, so exactly that set comes back.
        let runningClones = list().filter(\.isRunning).map(\.profile)
        let defaultWasRunning = runningDefaultPID() != nil
        CoreLog.update.info(
            """
            install: closing \(runningClones.count, privacy: .public) profile(s)\
            \(defaultWasRunning ? " and the default" : "", privacy: .public)
            """
        )

        for clone in runningClones {
            _ = await stop(clone, force: false, pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }
        if defaultWasRunning {
            _ = await stopDefault(pollInterval: stopPollInterval, maxPolls: stopMaxPolls)
        }

        guard await pollUntilNoBlockingInstances(interval: stopPollInterval, maxPolls: stopMaxPolls) else {
            // Read the blockers *before* reopening anything, or a profile that did quit and
            // is being restored here reappears in `ps` and gets blamed for the refusal.
            let stillRunning = blockingInstanceNames()
            let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
            CoreLog.update.error(
                "install: aborted, still running: \(stillRunning.joined(separator: ", "), privacy: .public)"
            )
            return InstallUpdateResult(outcome: .instancesStillRunning(stillRunning), relaunched: relaunched)
        }

        let outcome = swapInBundle(verified, previousVersion: previousVersion)
        let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
        CoreLog.update.info(
            "install: reopened \(relaunched.count, privacy: .public) profile(s)"
        )
        return InstallUpdateResult(outcome: outcome, relaunched: relaunched)
    }

    /// Replace the installed bundle, then tell LaunchServices about it.
    private func swapInBundle(
        _ verified: VerifiedUpdate,
        previousVersion: String?
    ) -> InstallUpdateResult.Outcome {
        do {
            _ = try fileManager.replaceItemAt(realClaude.appURL, withItemAt: verified.appURL)
        } catch {
            CoreLog.update.error("install: swap failed — \(error.localizedDescription, privacy: .public)")
            return .swapFailed(reason: error.localizedDescription)
        }
        // Without this the Dock, Spotlight and `open` can go on describing the old build for
        // a while: LaunchServices keyed its record on a bundle that has just been replaced
        // wholesale, at the same path and under the same identifier. Squirrel's installer
        // re-registers for the same reason. Best-effort — a stale record is cosmetic, and
        // failing the install over it would be worse than the symptom.
        if (try? runner.runChecked(CoreConstants.lsregisterPath, ["-f", realClaude.appURL.path])) == nil {
            CoreLog.update.error("install: lsregister refused; the Dock may describe the old build")
        }
        CoreLog.update.info("install: swapped in \(verified.version, privacy: .public)")
        return .installed(from: previousVersion, to: verified.version)
    }
}

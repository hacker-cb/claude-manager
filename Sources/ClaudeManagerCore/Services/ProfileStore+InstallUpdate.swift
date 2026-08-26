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
        /// The verified bundle is on a different volume from the installed app, so the swap
        /// could not be the atomic rename this promises.
        ///
        /// Measured, since the reason matters: a cross-volume `replaceItemAt` throws
        /// `NSCocoaErrorDomain 512` and leaves both sides untouched — it does *not* degrade
        /// into a copy. So this check buys a clear reason instead of an opaque error, and
        /// buys it **before** every profile is closed for a swap that was never going to
        /// happen.
        case differentVolume
        /// The process list could not be read, so "nothing is running" could not be
        /// established. Refused: this gate protects a live Electron process from having its
        /// bundle replaced underneath it, and a gate that cannot see is not a gate.
        case couldNotConfirmQuiet
        /// Claude's own Squirrel installer is running. Closing every profile is exactly what
        /// releases it to start, so it has to be checked *after* the quiesce, not before —
        /// and two installers writing the same bundle is how an install ends up as a mix of
        /// two versions.
        case claudeInstallerRunning
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
        // Asked before anything is closed: if the swap cannot work, closing every profile
        // first would be a cost paid for nothing.
        guard PathUtils.sameVolume(verified.appURL.path, realClaude.appURL.path) else {
            CoreLog.update.error("install: refused — staged bundle is on a different volume")
            return InstallUpdateResult(outcome: .differentVolume, relaunched: [])
        }
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

        // Everything above is a *wait*; this is the last look before the irreversible step,
        // and unlike the wait it is not allowed to guess.
        guard let remaining = blockingInstancesIfReadable() else {
            CoreLog.update.error("install: refused — could not read the process list")
            let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
            return InstallUpdateResult(outcome: .couldNotConfirmQuiet, relaunched: relaunched)
        }
        guard remaining.isEmpty else {
            // Named from the set just read, not from a fresh sweep: re-reading here could
            // come back empty and report "nothing is running" beside a refusal caused by
            // something that was.
            let names = names(for: remaining)
            let relaunched = relaunchSnapshot(clones: runningClones, defaultWasRunning: defaultWasRunning)
            CoreLog.update.error("install: an instance appeared after the quiesce")
            return InstallUpdateResult(outcome: .instancesStillRunning(names), relaunched: relaunched)
        }
        // Claude's own installer may have been armed and waiting for exactly what just
        // happened — every instance quitting. Two writers on one bundle produce whichever
        // half each one wins, so this steps aside rather than racing. Until the Squirrel
        // updater is switched off for good, this is a real state and not a theoretical one.
        if shipItProbe().isConfirmedRunning() {
            CoreLog.update.error("install: refused — Claude's own installer is running")
            // Deliberately no relaunch: reopening a profile now is what makes ShipIt abort
            // mid-copy, which is the failure this whole rewrite exists to stop causing.
            return InstallUpdateResult(outcome: .claudeInstallerRunning, relaunched: [])
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

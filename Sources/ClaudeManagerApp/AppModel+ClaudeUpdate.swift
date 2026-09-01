import ClaudeManagerCore
import Foundation

extension AppModel {
    // MARK: - Wiring

    /// The updater, assembled per call.
    ///
    /// Stateless by design — everything it needs is on disk — so there is nothing to keep
    /// alive between calls, and building it here keeps the cache location in one place.
    var claudeUpdateService: ClaudeUpdateService {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.hacker-cb.claude-manager"
        let cache = CoreConstants.updateCacheDirectory(forBundleID: bundleID)
        return ClaudeUpdateService(
            feed: UpdateFeed(),
            downloader: UpdateDownloader(cacheDirectory: cache),
            verifier: UpdateVerifier(runner: SystemCommandRunner()),
            stagingDirectory: cache.appendingPathComponent(CoreConstants.updateStagingDirectoryName)
        )
    }

    /// Show a plain message. The alert channel carries outcomes as well as failures — an
    /// install that postponed itself because a profile was busy is news, not an error.
    func presentInfo(title: String, message: String) {
        currentError = AppError(title: title, message: message)
    }

    // MARK: - Settings

    /// Whether Claude Manager fetches and installs Claude's updates itself.
    ///
    /// Backed by `defaults` rather than `@Published` (an extension cannot declare one), so
    /// the change notification is sent by hand.
    var managesClaudeUpdates: Bool {
        get {
            // Absent means on: this is the app's model of how Claude gets updated, and a
            // fresh install should behave like the feature exists rather than waiting to be
            // discovered in Settings.
            defaults.object(forKey: PreferenceKeys.manageClaudeUpdates) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: PreferenceKeys.manageClaudeUpdates)
            Log.claudeUpdate.info("managed updates \(newValue ? "on" : "off", privacy: .public)")
            // The default profile's overlay encodes this answer, so it has to be rewritten
            // now rather than at the next broker apply. Left until a relaunch, switching the
            // feature *off* would leave `disableAutoUpdates` in place — Claude would not
            // update itself and neither would this app: no update mechanism at all.
            //
            // Through the scheduler rather than a bare `Task`: each apply reads the setting
            // and then does async work, so two of them racing can finish out of order and
            // leave the *earlier* answer on disk. Toggling off and on quickly is exactly how
            // you would get there.
            scheduleBrokerApply()
            if newValue {
                startClaudeUpdateRefreshWhenIdle()
            } else if claudeUpdateState.blocksProfileActivity {
                // A swap is in flight. Dropping the state to `.idle` would re-enable profile
                // launches into a bundle being replaced, and the sweep would delete the staged
                // build out from under the copy — `installUpdate` does not hold the check's
                // slot, so nothing would make the sweep wait. Both halves are deferred to the
                // end of the install, which re-reads this setting (`sweepIfSwitchedOff`).
                Log.claudeUpdate.info("managed updates off during an install; sweep deferred")
            } else {
                setClaudeUpdateState(.idle)
                startClaudeUpdateCleanup()
            }
        }
    }

    /// When the feed last *answered*, or nil if it never has.
    ///
    /// The successful check rather than the last attempt, for the reason
    /// `PreferenceKeys.lastClaudeUpdateSuccess` gives: with Claude's own updater off, a feed
    /// that has been failing for a week means nothing is updating Claude at all, and only
    /// this stamp can tell that apart from a machine that is simply current.
    var lastClaudeUpdateSuccess: Date? {
        (defaults.object(forKey: PreferenceKeys.lastClaudeUpdateSuccess) as? Double)
            .map(Date.init(timeIntervalSince1970:))
    }

    /// Whether work owning the update cache is under way, for the controls that would start
    /// more of it.
    ///
    /// Neither half is visible in `claudeUpdateState`, which is why this is not that. Between
    /// asking the feed and hearing back the state is still `.idle`, and a button enabled
    /// through that window invites a second press the single-flight guard would drop in
    /// silence. The sweep is `.idle` throughout by construction — the feature is off — and it
    /// is deleting the very directory a new check would fetch into.
    var isCheckingClaudeUpdate: Bool {
        claudeUpdateTask != nil || claudeUpdateCleanupTask != nil || claudeUpdateRestoreTask != nil
    }

    /// The half of switching the feature off that something else postponed.
    ///
    /// Two callers, and neither is the setter. `installClaudeUpdate` runs it as it returns,
    /// because the setter deliberately leaves a swap in flight alone. And launch runs it,
    /// because that install may never have returned — quit or crash inside it and the setter
    /// will not fire again (the setting is already off), leaving hundreds of megabytes staged
    /// for a feature nobody has. A no-op in the ordinary case where the setting was untouched.
    func sweepIfSwitchedOff() {
        guard !managesClaudeUpdates else { return }
        setClaudeUpdateState(.idle)
        startClaudeUpdateCleanup()
    }

    /// Stop any in-flight fetch and delete everything staged.
    ///
    /// Three things have to be true at once, which is why this is not two lines inline.
    /// Cancellation is a request rather than a stop, so the sweep waits for the work to
    /// actually finish — otherwise a task part-way through unpacking finishes *after* the
    /// delete and leaves hundreds of megabytes staged for a feature that is off. The sweep
    /// itself occupies a single-flight slot, so a check cannot start beside it and
    /// race on the same cache directory. And it re-reads the setting before deleting: off
    /// and straight back on again is a real thing to do, and it must not cost the download
    /// that the second toggle just started.
    private func startClaudeUpdateCleanup() {
        // One sweep at a time. Off, on, off again is a real sequence, and without this the
        // second would overwrite the first's handle: two `discardEverything()` runs on one
        // directory, and the first to finish clearing the slot the other is still working in.
        // Nothing is lost by returning — the sweep re-reads the setting after the wait, so the
        // one already in flight acts on whatever the toggle finally says.
        guard claudeUpdateCleanupTask == nil else { return }
        // Both, because both write the cache this is about to delete: the check that fetches
        // into it, and the launch-time restore that unpacks into it to re-verify.
        let inFlight = claudeUpdateTask
        let restore = claudeUpdateRestoreTask
        inFlight?.cancel()
        restore?.cancel()
        let service = claudeUpdateService
        // Its own handle rather than the check's: the task it awaits clears `claudeUpdateTask`
        // as it finishes, which — parked there — would clear *this* one instead, leaving the
        // sweep running with the slot reading free and the button that reads it saying idle.
        claudeUpdateCleanupTask = Task { @MainActor [weak self] in
            await inFlight?.value
            await restore?.value
            defer { self?.claudeUpdateCleanupTask = nil }
            guard self?.managesClaudeUpdates == false else { return }
            await Task.detached(priority: .utility) { service.discardEverything() }.value
        }
    }

    // MARK: - Installing

    /// Install the prepared build. Closes every profile and reopens the same set.
    ///
    /// Only ever from a press. The swap takes the user's whole working set down for the time
    /// it runs, which is not something to do while they are looking the other way — and
    /// unlike the old staged-update path, nothing here is on a deadline, so there is no
    /// reason to.
    func installClaudeUpdate() async {
        guard case let .ready(verified) = claudeUpdateState else { return }
        // Whatever this returns through, the toggle may have gone off while the swap ran — see
        // `managesClaudeUpdates`, which defers its own teardown to exactly here.
        defer { sweepIfSwitchedOff() }
        // Asked again at the moment of the press, not only when the build was fetched: the
        // banner may have been sitting there while Claude updated itself underneath it, and
        // swapping in an equal-or-older bundle is a downgrade wearing an update's clothes.
        guard AvailableUpdate.isUpgrade(verified.version, over: realClaudeVersion) else {
            Log.claudeUpdate.info("install skipped; \(verified.version, privacy: .public) is not newer")
            discardPreparedUpdate()
            presentInfo(
                title: "Already up to date",
                message: "Claude has been updated since this build was prepared, so it was discarded."
            )
            return
        }
        setClaudeUpdateState(.installing(version: verified.version))
        Log.claudeUpdate.info("installing \(verified.version, privacy: .public)")

        guard let result = await perform({ store in await store.installUpdate(verified) }) else {
            setClaudeUpdateState(.failed(reason: "The update could not be installed."))
            return
        }
        switch result.outcome {
        case let .installed(_, version):
            Log.claudeUpdate.info("installed \(version, privacy: .public)")
            discardPreparedUpdate()
            // The bundle at `/Applications/Claude.app` is a different one now. Without this
            // every version the app displays stays stale until the next activation — and the
            // next scheduled check would compare against the old number and cheerfully fetch
            // the same build again.
            await locate()
            presentInfo(title: "Claude updated", message: Self.describeInstall(result, version: version))
        case let .instancesStillRunning(names):
            // Not a failure of the update — a profile is busy, and Claude refuses to quit
            // while a session is working. Back to ready so the button is there to try again.
            setClaudeUpdateState(.ready(verified))
            presentInfo(
                title: "Update postponed",
                message: "These profiles would not quit: \(names.joined(separator: ", ")). "
                    + "Claude declines to close while a session is working. The installed app was "
                    + "not touched, and the profiles that did close have been reopened."
            )
        case .claudeInstallerRunning:
            setClaudeUpdateState(.ready(verified))
            // The one outcome that leaves the profiles closed, deliberately — reopening one
            // now is what makes Claude's installer abort mid-copy. Waking up to an empty desk
            // with no explanation is not acceptable, so this says it outright.
            presentInfo(
                title: "Update postponed — your profiles are closed",
                message: "Claude's own installer is running, so your profiles were left closed: "
                    + "reopening one now would make it abort and start over. "
                    + "Wait for it to finish, then reopen them or try the update again."
            )
        case .couldNotConfirmQuiet:
            setClaudeUpdateState(.ready(verified))
            presentInfo(
                title: "Update postponed",
                message: "Could not confirm every Claude window had closed, so the installed app "
                    + "was not touched. Profiles that were closed have been reopened."
            )
        case .differentVolume:
            setClaudeUpdateState(.failed(reason: "The prepared build is on a different volume."))
        case let .swapFailed(reason):
            setClaudeUpdateState(.failed(reason: reason))
        }
    }

    /// Drop the prepared build and everything staged for it, off the main actor.
    ///
    /// Deleting an unpacked Electron bundle is tens of thousands of files; doing it inline
    /// would hang the UI at exactly the moment the user pressed something.
    func discardPreparedUpdate() {
        let service = claudeUpdateService
        Task.detached(priority: .utility) { service.discardEverything() }
        setClaudeUpdateState(.idle)
    }

    // MARK: - Launch guard

    /// Whether starting a profile right now would collide with an install, and say so.
    ///
    /// Two installers can be mid-swap on the shared bundle. **This app's**, during which a
    /// launch either trips its final no-instance check or leaves a process running out of a
    /// bundle that is about to be unlinked. And **Claude's own**, which re-counts instances
    /// while it copies and aborts with `App Still Running Error` if one appears — the
    /// failure that made a stuck update cost a fresh download every time. Squirrel is only
    /// disabled, not absent, so the second case is still real: updating can be handed back,
    /// and a job armed before the switch outlives it.
    func launchBlockedByUpdate() async -> Bool {
        if case .installing = claudeUpdateState {
            currentError = AppError(
                title: "Update in progress",
                message: "Claude is being updated. Wait for it to finish, then try again."
            )
            return true
        }
        guard await isClaudeInstallerRunning() else { return false }
        currentError = AppError(
            title: "Claude is being updated",
            message: "Claude's own installer is swapping Claude.app. Starting a profile now would "
                + "make it abort and start over — wait for it to finish, then try again."
        )
        return true
    }

    /// Off-actor probe for a live installer.
    ///
    /// Deliberately not routed through `perform`: that surfaces an alert when Claude cannot
    /// be located, and a *guard* must stay silent about anything but its own reason to refuse.
    /// `async` because the probe shells out and blocks on `waitUntilExit`.
    private func isClaudeInstallerRunning() async -> Bool {
        guard let configuration = currentConfiguration(), let real = realClaude else { return false }
        return await Task.detached {
            ProfileStore(realClaude: real, configuration: configuration)
                .shipItProbe()
                .isConfirmedRunning()
        }.value
    }

    // MARK: - Presentation helpers

    private static func describeInstall(_ result: InstallUpdateResult, version: String) -> String {
        guard !result.relaunched.isEmpty else { return "Claude \(version) is installed." }
        return "Claude \(version) is installed. Reopened: \(result.relaunched.joined(separator: ", "))."
    }

    /// A sentence for the user out of an error meant for a log.
    static func describeUpdateFailure(_ error: Error) -> String {
        switch error {
        case let failure as UpdateVerifier.Failure:
            switch failure {
            case .notAnthropicSigned, .signatureInvalid, .notNotarized:
                "The downloaded build could not be verified as Anthropic's, so it was discarded."
            case .unexpectedArchiveContents, .bundleIsNotADirectory:
                "The download did not contain a Claude app, so it was discarded."
            case .unexpectedBundleIdentifier, .versionMismatch:
                "The downloaded build was not the release that was offered, so it was discarded."
            }
        case let failure as UpdateFeed.Failure:
            switch failure {
            case .unexpectedStatus, .malformedPayload:
                "Anthropic's release service answered in a way this version does not understand."
            case .insecureDownloadURL:
                "The release service offered an insecure download, which was refused."
            }
        default:
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

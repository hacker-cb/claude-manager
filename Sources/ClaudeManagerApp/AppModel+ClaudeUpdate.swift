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

    /// Clear the sweep slot, but only while it still belongs to that sweep.
    private func releaseCleanupSlot(_ generation: Int) {
        guard claudeUpdateCleanupGeneration == generation else { return }
        claudeUpdateCleanupTask = nil
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
        claudeUpdateCleanupGeneration += 1
        let generation = claudeUpdateCleanupGeneration
        claudeUpdateCleanupTask = Task { @MainActor [weak self] in
            await inFlight?.value
            await restore?.value
            defer { self?.releaseCleanupSlot(generation) }
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
    ///
    /// Two questions are asked at the press rather than trusted from when the build was
    /// fetched, because an offer can wait for days: whether the installed app has caught up
    /// with it (a downgrade wearing an update's clothes), and whether Anthropic has shipped
    /// something newer since (a press that costs the user their whole working set to install a
    /// build that is already old, and buys a second download besides).
    func installClaudeUpdate() async {
        guard case let .ready(verified) = claudeUpdateState else { return }
        // Whatever this returns through, the toggle may have gone off while the swap ran — see
        // `managesClaudeUpdates`, which defers its own teardown to exactly here.
        defer { sweepIfSwitchedOff() }
        // Refused, but the build is kept. `isUpgrade` says `false` for a baseline it could not
        // read exactly as it does for one that has caught up, and treating the two alike here
        // deletes several hundred verified megabytes because a plist was caught mid-write — and
        // explains it with "Claude has been updated since", which is not what happened.
        guard let installed = realClaudeVersion, AvailableUpdate.isComparableVersion(installed)
        else {
            Log.claudeUpdate.error("install skipped; installed version unreadable")
            presentInfo(
                title: "Claude's version could not be read",
                message: "Claude Manager could not read a usable version from Claude.app, so it "
                    + "cannot tell whether this build is newer. The download was kept — try "
                    + "Re-detect in Settings, then install again."
            )
            return
        }
        // Asked again at the moment of the press, not only when the build was fetched: the
        // offer may have been sitting there while Claude updated itself underneath it, and
        // swapping in an equal-or-older bundle is a downgrade wearing an update's clothes.
        guard AvailableUpdate.isUpgrade(verified.version, over: installed) else {
            Log.claudeUpdate.info("install skipped; \(verified.version, privacy: .public) is not newer")
            discardPreparedUpdate()
            presentInfo(
                title: "Already up to date",
                message: "Claude has been updated since this build was prepared, so it was discarded."
            )
            return
        }
        // Claimed here, and **before the first `await` in this method** — the guards above are
        // all synchronous precisely so that nothing can slip between them and this line. Two
        // things ride on it. A second press finds `.installing` and turns back at the guard at
        // the top. And a check cannot start beside the swap: `allowsCheck` is false for this
        // state, and one already part-way through drops its answer on `refreshClaudeUpdate`'s
        // own `isBusy` guard rather than fetching into the cache being read here.
        setClaudeUpdateState(.installing(version: verified.version))
        // Then stop whatever was already running, because claiming the state does not unwind
        // work in flight: a check that got past its guards is still holding the cache.
        await quiesceClaudeUpdateWork()
        // The second question, and the one this app used to get wrong. Until now the only
        // baseline was `/Applications`: an offer prepared on Monday and pressed on Thursday
        // still read as "newer than what is installed", so the swap went ahead with a build two
        // releases behind — and the next check, minutes later, fetched the current one and
        // asked for every profile to close all over again.
        //
        // A feed that does not answer is not an answer: it leaves this nil and the install
        // proceeds with the build it has, which is what an offline machine wants anyway.
        if let newer = await newerReleaseSuperseding(verified) {
            Log.claudeUpdate.info(
                """
                install stopped; \(newer.version, privacy: .public) supersedes the prepared \
                \(verified.version, privacy: .public)
                """
            )
            // `.downloading`, and only then the delete. Something has to gate the suspension
            // below — `.available` allows a check, and `quiesce` has just emptied the slots, so
            // a monitor tick inside it would fetch into the directory being deleted and take
            // the single-flight slot, leaving `startClaudeUpdateFetch` to return at its own busy
            // guard having promised the user a download. But that gate must not be
            // `.installing`: this branch has decided *not* to install, while `.installing` is
            // what `launchBlockedByUpdate` reads — every profile the user clicked in those
            // seconds would be refused with "Claude is being updated", for a swap that is not
            // happening. `.downloading` refuses checks identically and blocks no profile, and it
            // names the release actually about to be fetched.
            //
            // See `discardStagedBuild` for why the bundle goes now rather than at the next
            // verification.
            setClaudeUpdateState(.downloading(version: newer.version, received: 0, total: nil))
            await discardStagedBuild()
            // Not gated through `publishClaudeUpdateState`: that one refuses to write over
            // `.installing`, which is the state this line is undoing. Nothing between here and
            // the fetch below suspends, so no check can slip into the gap.
            setClaudeUpdateState(.available(newer))
            presentInfo(
                title: "A newer Claude was released",
                message: "Claude \(newer.version) came out after \(verified.version) was "
                    + "downloaded, so that build was not installed — your profiles were left "
                    + "open. Claude Manager is fetching \(newer.version) now; press Install "
                    + "again when it is ready."
            )
            startClaudeUpdateFetch(of: newer)
            return
        }
        Log.claudeUpdate.info("installing \(verified.version, privacy: .public)")

        guard let result = await perform({ store in await store.installUpdate(verified) }) else {
            setClaudeUpdateState(.failed(reason: "The update could not be installed."))
            return
        }
        await reportInstallOutcome(result, verified: verified)
    }

    /// Say what the swap came to, and leave the state where that outcome belongs.
    ///
    /// Split out of `installClaudeUpdate` for length, and it divides cleanly: everything
    /// above decides *whether* to install — the quiesce, the two version questions, the
    /// feed — while this is the report, with nothing left to decide. Three of the six are
    /// postponements rather than failures and go back to `.ready` so the button is there to
    /// try again.
    private func reportInstallOutcome(
        _ result: InstallUpdateResult, verified: VerifiedUpdate
    ) async {
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
        // The two outcomes that are actually failures, and the only two that used to be read
        // off a strip in the window. The offer lives in the toolbar now, where a failure is an
        // icon and its reason is a click away — so a swap that fell over says so here as well,
        // like every postponement above it. The state keeps the reason too: the alert is
        // dismissed once, the button stays until something changes it.
        case .differentVolume:
            let reason = "The prepared build ended up on a different volume, so the swap could "
                + "not be atomic. The installed app was not touched."
            setClaudeUpdateState(.failed(reason: reason))
            presentInfo(title: "Update failed", message: reason)
        case let .swapFailed(reason):
            setClaudeUpdateState(.failed(reason: reason))
            presentInfo(title: "Update failed", message: reason)
        }
    }

    /// A release that supersedes the prepared build, or nil — including when the feed could
    /// not be asked.
    ///
    /// Collapsing "nothing newer" and "could not ask" is deliberate *here*, and it is the
    /// opposite of what a background check does with the same two answers. There the
    /// difference is the whole point: a feed unreachable for a week means nothing is updating
    /// Claude, and Doctor has to be able to say so. At a press it is a question of what to do
    /// next, and both answers give the same one — go ahead with the verified build already on
    /// disk. Refusing to install because a laptop is offline would strand the user with a
    /// download they cannot use.
    ///
    /// The baseline is the prepared build, so the feed's own copy of it comes back as nil.
    private func newerReleaseSuperseding(_ verified: VerifiedUpdate) async -> AvailableUpdate? {
        do {
            return try await claudeUpdateService.checkForUpdate(
                installedVersion: verified.version,
                timeout: CoreConstants.updateFeedPressTimeout
            )
        } catch {
            // Logged, not shown: the press asked for an install, and it is getting one.
            Log.claudeUpdate.error(
                "install: could not re-check the feed — \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Stop everything that writes the update cache, and wait until it has actually stopped.
    ///
    /// A check and an install never overlapped while a prepared build silenced every check;
    /// now that it does not, this is what keeps them apart. Cancellation is a request rather
    /// than a stop — a task part-way through `ditto` finishes its write whatever its
    /// cancellation flag says — so both handles are awaited rather than merely cancelled.
    ///
    /// The sweep is awaited but never cancelled: it is deleting the cache on behalf of a
    /// feature the user has switched off, and interrupting it would leave hundreds of
    /// megabytes staged for nobody. It cannot ordinarily be running here at all — switching the
    /// feature off drops the state to `.idle`, which no press gets past — so this is the belt
    /// to the state's braces.
    private func quiesceClaudeUpdateWork() async {
        let check = claudeUpdateTask
        let restore = claudeUpdateRestoreTask
        let sweep = claudeUpdateCleanupTask
        guard check != nil || restore != nil || sweep != nil else { return }
        Log.claudeUpdate.info("install: waiting for update work to stop")
        check?.cancel()
        restore?.cancel()
        await check?.value
        await restore?.value
        await sweep?.value
    }

    /// Drop the prepared build and everything staged for it, off the main actor.
    ///
    /// Deleting an unpacked Electron bundle is tens of thousands of files; doing it inline
    /// would hang the UI at exactly the moment the user pressed something.
    func discardPreparedUpdate() {
        let service = claudeUpdateService
        setClaudeUpdateState(.idle)
        // In the sweep's slot, not detached and forgotten. `.idle` frees the schedule, the
        // activation tick and both buttons to start a check the instant this returns, and that
        // check fetches into the very directories being deleted.
        //
        // Chained behind a sweep already in the slot rather than skipped: that one re-reads the
        // setting and exits *without deleting* if the feature was switched back on inside it,
        // so skipping would leave the discarded build on disk with the state saying `.idle`.
        let previous = claudeUpdateCleanupTask
        // And the check, cancelled and awaited exactly as the sweep does it. A check can now be
        // mid-request over a prepared build, and `reconcile` reaches here the moment the user
        // comes back to an app whose Claude was updated underneath it: the `.idle` set above
        // passes that request's own guards, so without this it would fetch and unpack into the
        // directories this is deleting.
        let inFlight = claudeUpdateTask
        let restore = claudeUpdateRestoreTask
        // The stamp goes with the check being cancelled. `startClaudeUpdateRefresh` records the
        // attempt *before* spawning the task, so a check killed here has silenced the schedule
        // for four hours on behalf of an answer nobody will ever see — and nothing retries it:
        // the activation tick that follows is refused by that stamp and by this sweep holding
        // the slot. `lastClaudeUpdateSuccess` does not move either, which is exactly what Doctor
        // reads as a feed that has stopped answering.
        if inFlight != nil { defaults.removeObject(forKey: PreferenceKeys.lastClaudeUpdateCheck) }
        inFlight?.cancel()
        restore?.cancel()
        claudeUpdateCleanupGeneration += 1
        let generation = claudeUpdateCleanupGeneration
        claudeUpdateCleanupTask = Task { @MainActor [weak self] in
            defer { self?.releaseCleanupSlot(generation) }
            await previous?.value
            await inFlight?.value
            await restore?.value
            await Task.detached(priority: .utility) { service.discardEverything() }.value
        }
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

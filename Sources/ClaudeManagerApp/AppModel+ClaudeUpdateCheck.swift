import ClaudeManagerCore
import Foundation

/// Asking Anthropic's release service what is current, and fetching what it offers.
///
/// Three files rather than one, split by what each is responsible for and kept apart so none
/// outgrows its length budget: `AppModel+ClaudeUpdate` owns the setting, the install and the
/// launch guard; `AppModel+ClaudeUpdateReport` owns the press that asks for a check and every
/// sentence a check says back; and this one owns the schedule, the request and the fetch.
extension AppModel {
    // MARK: - The schedule

    /// How often the feed is worth asking. Claude ships a build every few days, so anything
    /// more frequent is load without news — and the check also runs whenever the user comes
    /// back to the app, which is what makes it feel current.
    static let claudeUpdateCheckInterval: TimeInterval = 4 * 3600

    /// Run a check if one is due, remembering when the last one happened.
    ///
    /// The timestamp is persisted rather than kept in memory: a menu-bar app is relaunched
    /// often, and an in-memory clock would turn "every four hours" into "on every launch".
    func refreshClaudeUpdateIfDue(now: Date = Date()) {
        guard managesClaudeUpdates, claudeUpdateState.allowsCheck else { return }
        let last = (defaults.object(forKey: PreferenceKeys.lastClaudeUpdateCheck) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        guard ClaudeUpdateState.isCheckDue(
            lastCheck: last, now: now, interval: Self.claudeUpdateCheckInterval
        ) else { return }
        startClaudeUpdateRefresh(now: now)
    }

    /// Re-establish a build prepared before the last quit, then check on the usual schedule.
    ///
    /// Called once at startup. Without it a build downloaded and verified minutes before a
    /// relaunch is invisible — the state lives in memory — and the schedule would not look
    /// again for hours with several hundred verified megabytes already on disk.
    func restoreClaudeUpdateState() {
        // Switched off, so there is nothing to restore — but possibly something to delete: the
        // sweep that switching it off starts is deferred past an install, and an app that quit
        // inside one never ran it. No other caller is left, the setting being already off.
        guard managesClaudeUpdates else {
            sweepIfSwitchedOff()
            return
        }
        guard !isCheckingClaudeUpdate, case .idle = claudeUpdateState else { return }
        // `restorePrepared` discards whatever it cannot call newer, and `isUpgrade` cannot
        // call anything newer than a baseline it failed to read — so a launch that catches
        // Claude.app mid-write would delete a verified build on the strength of a plist that
        // was unreadable for a second. Left on disk for the next launch instead.
        guard let installed = realClaudeVersion, AvailableUpdate.isComparableVersion(installed)
        else {
            Log.claudeUpdate.error("restore skipped; installed version unreadable")
            return
        }
        let service = claudeUpdateService
        // In a slot of its own, and `isCheckingClaudeUpdate` counts it: re-verifying unpacks
        // into the same staging directory a fetch writes to, so nothing else may touch the
        // cache while it runs. The schedule used to be the only other caller and it waits for
        // this to finish; the manual check waits for nothing, so without the slot a press
        // seconds after launch runs `prepare` into a directory `restorePrepared` is still
        // verifying — and whose failure path deletes it.
        claudeUpdateRestoreTask = Task { @MainActor [weak self] in
            // Off the main actor: re-verifying unpacks and runs `codesign` over an Electron
            // bundle, which is seconds of work.
            let restored = await Task.detached(priority: .utility) {
                service.restorePrepared(newerThan: installed)
            }.value
            // Released before the guard, not after: an early return must not strand the slot
            // and leave every later check refusing to start.
            self?.claudeUpdateRestoreTask = nil
            guard let self, case .idle = self.claudeUpdateState else { return }
            // Through the gate: re-verifying takes seconds, and the toggle can go off inside
            // them.
            if let restored { publishClaudeUpdateState(.ready(restored)) }
            refreshClaudeUpdateIfDue()
        }
    }

    /// Start a check-and-fetch, unless one is already running.
    ///
    /// Returns immediately. Fetching a build takes minutes on a slow line, and the monitor
    /// loop that calls this also drives the profile sweep, and awaiting a download inside it
    /// would stop that clock for the whole transfer.
    ///
    /// The task handle is what makes this single-flight. `UpdateDownloader` states plainly
    /// that overlapping fetches are the caller's to prevent, and two of them would write the
    /// same cache names and race each other's published state.
    func startClaudeUpdateRefresh(
        now: Date = Date(), announcing: ClaudeUpdateAnnouncement = .silently
    ) {
        // `allowsCheck` as well as the slot: `startClaudeUpdateRefreshWhenIdle` can reach here
        // with an install still in flight, and the stamp below would then silence the schedule
        // for four hours on behalf of a check that `refreshClaudeUpdate` drops on its own guard
        // without asking anybody anything.
        // The baseline too, and *before* the stamp below. `refreshClaudeUpdate` refuses an
        // unreadable installed version — rightly, its answer would mean nothing — but it does so
        // after this line has recorded an attempt that never reached the network, which then
        // silences the schedule for four hours. The usual cause is Claude's own installer
        // swapping the bundle, i.e. a state that clears itself in seconds.
        guard managesClaudeUpdates, claudeUpdateState.allowsCheck, !isCheckingClaudeUpdate,
              let installed = realClaudeVersion, AvailableUpdate.isComparableVersion(installed)
        else { return }
        // Stamped when the attempt *starts*: this throttles asking Anthropic, and an attempt
        // that got as far as the network has asked. A failed download is retried by its own
        // state (`.failed` and `.available` both allow a check) rather than by re-asking the
        // feed every minute.
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateCheck)
        claudeUpdateTask = Task { @MainActor [weak self] in
            await self?.refreshClaudeUpdate(announcing: announcing)
            self?.claudeUpdateTask = nil
        }
    }

    /// Start a check as soon as the slot frees, rather than dropping it.
    ///
    /// Switching the feature back on is precisely when a check is wanted, and the sweep that
    /// switching it *off* started can still hold the slot — deleting an unpacked Electron
    /// bundle is tens of thousands of files. Dropped, that check is not retried by anything:
    /// the attempt stamped before the toggle silences the schedule for up to four hours.
    func startClaudeUpdateRefreshWhenIdle() {
        guard let sweep = claudeUpdateCleanupTask else {
            startClaudeUpdateRefresh()
            return
        }
        Task { @MainActor [weak self] in
            await sweep.value
            // Re-read, because the toggle can go off again inside the wait.
            guard self?.managesClaudeUpdates == true else { return }
            self?.startClaudeUpdateRefresh()
        }
    }

    // MARK: - Checking and preparing

    /// Ask the feed, and fetch what it offers.
    ///
    /// Both halves run unattended, and both are safe to: nothing here touches the installed
    /// app or the user's profiles. The bytes land in a cache and the verified bundle waits
    /// beside them until someone presses the button.
    func refreshClaudeUpdate(announcing: ClaudeUpdateAnnouncement = .silently) async {
        guard managesClaudeUpdates else { return }
        // The same question every caller already asks, restated here because this is where it
        // has teeth: a download owns the cache this would fetch into, and an install owns both
        // the state and the staging directory it is moving into `/Applications`. A prepared
        // build is deliberately *not* on that list — see `allowsCheck` — and the rule that
        // replaces it is further down: only a release that supersedes it, never a re-fetch of
        // the build already on disk.
        guard claudeUpdateState.allowsCheck else { return }

        // The same refusal the press makes, for the same reason: with no comparable baseline
        // the feed's answer cannot mean anything, `checkForUpdate` returns nil on every tick,
        // and the success stamped below is what keeps Doctor quiet about a machine nothing is
        // updating. The press explains itself; the schedule has only the log.
        guard let installed = realClaudeVersion, AvailableUpdate.isComparableVersion(installed)
        else {
            Log.claudeUpdate.error("check skipped; installed version unreadable")
            return
        }
        let available: AvailableUpdate?
        do {
            available = try await claudeUpdateService.checkForUpdate(installedVersion: installed)
            // Recorded on success only. With Claude's updater off, a feed that has been
            // unreachable for weeks means nothing is updating Claude — and without this,
            // that is indistinguishable from a machine that is simply current.
            //
            // The notification is sent by hand because the stamp is `defaults`, not
            // `@Published`: for a check that finds nothing, the settings row turning from
            // "Last checked 4 h ago" to "just now" is the entire visible outcome, and nothing
            // else would tell SwiftUI to re-read it.
            objectWillChange.send()
            defaults.set(Date().timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateSuccess)
            setClaudeUpdateCheckFailure(nil)
        } catch {
            // Unreachable is not "up to date", but for the schedule it is also not worth a
            // notice: a laptop is offline all the time. Logged, and left for the next tick.
            Log.claudeUpdate.error("check failed — \(error.localizedDescription, privacy: .public)")
            reportFailedCheck(error, announcing: announcing)
            return
        }
        // Asked again after the await, not only before it. The feed call suspends for seconds
        // and an install can begin inside them: every publish below would then overwrite
        // `.installing` — which `blocksProfileActivity` and `launchBlockedByUpdate` read to
        // keep profiles closed through the swap — and `prepare` would rewrite the staging
        // directory `installUpdate` is about to move into `/Applications`, leaving a
        // half-extracted bundle where a verified one belonged.
        guard !claudeUpdateState.isBusy else { return }
        // Cancelled counts too, and the state cannot stand in for it. Cancelling is a request:
        // the feed's answer can already be in hand when `discardPreparedUpdate` cancels this
        // task, and the `.idle` it publishes is not busy — so without this the continuation
        // sails on, fetches, verifies, publishes `.ready`, and the sweep that was waiting for
        // it politely deletes the bundle that state now advertises.
        guard !Task.isCancelled else {
            Log.claudeUpdate.info("check cancelled after the feed answered; dropping the result")
            return
        }
        guard let available else {
            // A prepared build is kept unless the *installed* app has caught up with it. `nil`
            // says the feed offers nothing newer than what is installed, which is a different
            // sentence: with 1.0 installed, 2.0 prepared and the feed rolled back to 1.0, this
            // answers nil while the verified build on disk is still an upgrade — and discarding
            // it there would throw away 335 MB and the only Install button on the strength of a
            // release someone withdrew. It is also the comparison `restorePrepared` makes at
            // launch, so the two would otherwise disagree about the same bundle.
            if case let .ready(verified) = claudeUpdateState {
                if AvailableUpdate.isUpgrade(verified.version, over: installed) {
                    announce(
                        announcing,
                        title: "Claude \(verified.version) is ready to install",
                        message: "The release service offers nothing newer, and this build is "
                            + "still an upgrade over the installed Claude \(installed) — press "
                            + "Install when you are ready for your profiles to close."
                    )
                    return
                }
            }
            // Otherwise anything staged describes a build that is no longer newer — usually
            // because it has just been installed. `.idle` **before** the delete, not after:
            // deleting an unpacked Electron bundle is tens of thousands of files and this
            // suspends for the whole of it, and the Install button reads the state — left at
            // `.ready`, it goes on offering the bytes being removed, and a press landing in
            // that window closes every profile to swap in a bundle that is no longer there.
            let wasPrepared = claudeUpdateState.isPreparedForInstall
            publishClaudeUpdateState(.idle)
            if wasPrepared { await discardStagedBuild() }
            announce(
                announcing,
                title: "Claude is up to date",
                // "Nothing newer", not "the latest release": `checkForUpdate` answers nil for an
                // installed build *ahead* of the feed too — a prerelease, or a release the feed
                // has rolled back — and calling that one the latest is simply false.
                message: "No newer release is available. Claude \(installed) is installed."
            )
            return
        }
        // What the answer means for a build already waiting on a press. Two outcomes, and the
        // wrong one is expensive either way: re-fetching the version already on disk throws
        // away a finished download to arrive back where we started, while keeping a superseded
        // one means the press installs a build that was current when it was fetched — and pays
        // for a second download and a second round of closing every profile as soon as the next
        // check runs.
        if case let .ready(verified) = claudeUpdateState {
            guard available.supersedes(prepared: verified.version) else {
                announce(
                    announcing,
                    title: "Claude \(verified.version) is ready to install",
                    message: "It is still the newest release — press Install when you are ready "
                        + "for your profiles to close."
                )
                return
            }
            Log.claudeUpdate.info(
                """
                prepared \(verified.version, privacy: .public) superseded by \
                \(available.version, privacy: .public); refetching
                """
            )
            // Said out loud for a manual check, because the offer the user was looking at is
            // about to disappear: `prepare` publishes `.downloading`, which takes the Install
            // button away for the length of a transfer that can run for minutes.
            announce(
                announcing,
                title: "A newer Claude was released",
                message: "Claude \(available.version) supersedes the \(verified.version) build "
                    + "that was waiting, so that one was discarded. The new build is downloading "
                    + "now — press Install when it is ready."
            )
            // The state moves off `.ready` **before** the delete suspends, and that order is the
            // whole point: deleting an unpacked Electron bundle is tens of thousands of files,
            // and the Install button reads this state. Left at `.ready` for the length of it,
            // the button goes on offering bytes that are being removed — and a press landing in
            // that window passes every guard, closes every profile, and fails the swap on a
            // bundle that is no longer there.
            publishClaudeUpdateState(.downloading(version: available.version, received: 0, total: nil))
            // Deleted now rather than at the next verification. `fetch` drops the superseded
            // *archive* by itself, but the ~800 MB unpacked beside it would otherwise sit there
            // for the length of the download — and survive a quit inside it with nothing left
            // on disk that describes it, since `restorePrepared` looks for an archive.
            await discardStagedBuild()
        }
        await prepareClaudeUpdate(available)
    }

    /// Delete everything staged, off the main actor and without touching the state.
    ///
    /// `discardPreparedUpdate` is the other half of this and publishes `.idle` on the way,
    /// which is right where a press or a reconcile ends the offer — and wrong here, where the
    /// state is about to become `.downloading` for the release that replaced it.
    func discardStagedBuild() async {
        let service = claudeUpdateService
        await Task.detached(priority: .utility) { service.discardEverything() }.value
    }

    /// Fetch a release this app has *just* been told about, in the check's slot.
    ///
    /// One caller: the press, whose re-check already holds an `AvailableUpdate` and would
    /// otherwise have to ask the feed a second time within the same second to get back here.
    /// Everything else `startClaudeUpdateRefresh` does is kept, because it is all still true —
    /// the stamps (the feed did answer, just now) and the single-flight slot, without which
    /// this download would race the next scheduled check over one cache directory.
    func startClaudeUpdateFetch(of update: AvailableUpdate, now: Date = Date()) {
        guard managesClaudeUpdates, !isCheckingClaudeUpdate else { return }
        objectWillChange.send()
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateCheck)
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateSuccess)
        setClaudeUpdateCheckFailure(nil)
        claudeUpdateTask = Task { @MainActor [weak self] in
            await self?.prepareClaudeUpdate(update)
            self?.claudeUpdateTask = nil
        }
    }

    /// Throw away a prepared build that the installed app has caught up with.
    ///
    /// Called from `reconcile`, which re-reads the installed version whenever the user comes
    /// back to the app. A check reaches the same verdict — it runs over a prepared build now,
    /// and a feed offering nothing newer than what is installed discards whatever is staged —
    /// but only over the network and only when one is due. This is the local answer, available
    /// the moment the user switches back: Claude replaced by hand or by an installer of its own
    /// leaves a prepared build that is no longer newer, and pressing Install would swap in
    /// something equal or older — a downgrade dressed as an update.
    func discardPreparedIfOvertaken(by installed: String?) {
        guard case let .ready(verified) = claudeUpdateState else { return }
        // A baseline that cannot be read is not evidence the prepared build was overtaken:
        // `isUpgrade` answers false for it exactly as it does for a genuinely older release, and
        // acting on that would discard a verified build because a plist went unreadable for a
        // moment.
        guard let installed, AvailableUpdate.isComparableVersion(installed) else { return }
        guard !AvailableUpdate.isUpgrade(verified.version, over: installed) else { return }
        Log.claudeUpdate.info(
            "discarding prepared \(verified.version, privacy: .public); no longer newer than installed"
        )
        discardPreparedUpdate()
    }

    /// Publish a state, unless something else owns it.
    ///
    /// Two owners, and both would otherwise be overwritten by work that outlived its welcome.
    /// Cancelling a task does not unwind the work already inside it: `prepare` can be most of
    /// the way through a verification when the toggle goes off, finish a moment later, and
    /// publish `.ready` for a feature that no longer exists. And an **install owns the state
    /// until it is done** — it closes every profile and swaps the bundle, while
    /// `blocksProfileActivity` (this value, read by the sweep, the launch guard and every
    /// profile row) is what keeps anything from opening a profile mid-swap. `installClaudeUpdate`
    /// writes its own transitions through `setClaudeUpdateState`, so it is not gated here.
    ///
    /// Reachable from `AppModel+ClaudeUpdateReport` as well, which records a failed check into
    /// the state — the gate is what makes that safe from either side.
    func publishClaudeUpdateState(_ state: ClaudeUpdateState) {
        // `Task.isCancelled` reads false outside a task, so the synchronous callers are
        // unaffected — the same gate `announce` applies for the same reason. Inside one it is
        // the second half of the guard above: cancellation does not unwind work already
        // running, so a `prepare` most of the way through a verification finishes after the
        // sweep cancelled it, and would publish `.ready` for bytes about to be deleted.
        guard !Task.isCancelled, managesClaudeUpdates, !claudeUpdateState.blocksProfileActivity
        else { return }
        setClaudeUpdateState(state)
    }

    /// Download and verify, reporting progress as it goes.
    ///
    /// Awaited directly rather than pushed onto a detached task, and that is deliberate.
    /// `ClaudeUpdateService.prepare` is `nonisolated async`, so its body — including the
    /// verification that unpacks 800 MB and blocks on `codesign` and `spctl` — does **not**
    /// run on the main actor even when awaited from one. Measured: synchronous work inside a
    /// `nonisolated async` method called from a `@MainActor` context reports
    /// `pthread_main_np() == 0`.
    ///
    /// Detaching would also break cancellation, which matters more: a detached task does not
    /// inherit it, so switching the feature off would stop watching the download without
    /// stopping the download.
    func prepareClaudeUpdate(_ update: AvailableUpdate) async {
        publishClaudeUpdateState(.downloading(version: update.version, received: 0, total: nil))
        do {
            let verified = try await claudeUpdateService.prepare(update) { [weak self] received, total in
                Task { @MainActor in
                    guard let self else { return }
                    // Only while this download is still the thing happening: a cancelled or
                    // superseded transfer must not drag the UI backwards.
                    guard case .downloading = self.claudeUpdateState else { return }
                    self.publishClaudeUpdateState(
                        .downloading(version: update.version, received: received, total: total)
                    )
                }
            }
            publishClaudeUpdateState(.ready(verified))
        } catch is CancellationError {
            publishClaudeUpdateState(.available(update))
        } catch let interrupted as DownloadInterrupted {
            // Resumable and expected on a laptop; the next tick continues where it stopped.
            Log.claudeUpdate.error(
                "download interrupted — \(interrupted.underlying.localizedDescription, privacy: .public)"
            )
            publishClaudeUpdateState(.available(update))
        } catch {
            Log.claudeUpdate.error("prepare failed — \(String(describing: error), privacy: .public)")
            publishClaudeUpdateState(.failed(reason: Self.describeUpdateFailure(error)))
        }
    }
}

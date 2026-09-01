import ClaudeManagerCore
import Foundation

/// How a check reports what it found.
///
/// Three answers rather than a flag, because the two manual paths differ in where the user is
/// looking. Settings has the status line in front of it, so the outcome reaching the *state*
/// is the answer, and an alert written from there would be presented by the main window's
/// modifier — a window that may not even be open, and that would then ambush the user with a
/// stale verdict hours later. The menu bar and the banner have no such line, so they take the
/// alert as well. The schedule stays quiet: a laptop is offline all the time, and a banner per
/// closed lid is noise.
enum ClaudeUpdateAnnouncement {
    /// The scheduled check: the log, and nothing else.
    case silently
    /// A press beside the status line, which renders whatever the state becomes.
    case inTheStatusLine
    /// A press with no status line in view: the state, plus an alert in the window.
    case withAnAlert

    /// Whether the user asked for this check. The two manual cases record a failure in the
    /// state where the schedule deliberately does not.
    var isManual: Bool {
        self != .silently
    }

    var showsAnAlert: Bool {
        self == .withAnAlert
    }
}

/// Asking Anthropic's release service what is current, and fetching what it offers. Split from
/// `AppModel+ClaudeUpdate` — which owns the setting, the install and the launch guard — so
/// neither file outgrows its length budget.
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
        guard managesClaudeUpdates, !isCheckingClaudeUpdate, case .idle = claudeUpdateState
        else { return }
        let service = claudeUpdateService
        let installed = realClaudeVersion
        // In the single-flight slot, because re-verifying unpacks into the same staging
        // directory a fetch writes to. The schedule used to be the only other caller and it
        // waits for this one to finish; the manual check does not wait for anything, so
        // without the slot a press seconds after launch runs `prepare` into a directory
        // `restorePrepared` is still verifying — and whose failure path deletes it.
        claudeUpdateTask = Task { @MainActor [weak self] in
            // Off the main actor: re-verifying unpacks and runs `codesign` over an Electron
            // bundle, which is seconds of work.
            let restored = await Task.detached(priority: .utility) {
                service.restorePrepared(newerThan: installed)
            }.value
            // Released before the guard, not after: an early return must not strand the slot
            // and leave every later check refusing to start.
            self?.claudeUpdateTask = nil
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
        guard managesClaudeUpdates, !isCheckingClaudeUpdate else { return }
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

    // MARK: - The button

    /// Check now because someone pressed a button, and say what came of it.
    ///
    /// Two things separate this from the scheduled path, and both are the point. It ignores
    /// the four-hourly throttle — a button that answers "not yet, come back at half past two"
    /// is not a button. And it reports its outcome: a background check that finds nothing is
    /// right to stay silent, but a press that changes nothing on screen is indistinguishable
    /// from one that did nothing at all, which is what an unreachable feed looked like for a
    /// whole day before this existed.
    func checkForClaudeUpdateNow(announcing: ClaudeUpdateAnnouncement = .withAnAlert) {
        guard managesClaudeUpdates else {
            announce(
                announcing,
                title: "Claude updates are switched off",
                message: "Turn \u{201C}Let Claude Manager update Claude\u{201D} back on in Settings and "
                    + "Claude Manager will fetch new builds again."
            )
            return
        }
        // Both halves, and neither covers the other. `allowsCheck` is false for a build
        // already prepared — asking again cannot improve on it — and for a swap in flight,
        // where resuming would rewrite the staging directory `installUpdate` is about to move
        // into `/Applications`. `isCheckingClaudeUpdate` is the separate question of whether
        // one is already under way: an install runs in a task of its own, so the handle alone
        // would let a press through to stamp the throttle and then die, wordlessly, on
        // `refreshClaudeUpdate`'s busy guard — the "did I press it?" failure this exists to
        // remove.
        guard claudeUpdateState.allowsCheck, !isCheckingClaudeUpdate else {
            announce(
                announcing,
                title: "Already working on it",
                message: claudeUpdateState.allowsCheck
                    ? "A check is already under way, and will say what it finds."
                    : claudeUpdateState.statusLine(lastSuccess: lastClaudeUpdateSuccess)
            )
            return
        }
        startClaudeUpdateRefresh(announcing: announcing)
    }

    /// Say something, if this check's voice carries that far — see `ClaudeUpdateAnnouncement`
    /// for why the settings path deliberately says nothing here.
    private func announce(
        _ voice: ClaudeUpdateAnnouncement, title: String, message: String
    ) {
        guard voice.showsAnAlert else { return }
        presentInfo(title: title, message: message)
    }

    // MARK: - Checking and preparing

    /// Ask the feed, and fetch what it offers.
    ///
    /// Both halves run unattended, and both are safe to: nothing here touches the installed
    /// app or the user's profiles. The bytes land in a cache and the verified bundle waits
    /// beside them until someone presses the button.
    func refreshClaudeUpdate(announcing: ClaudeUpdateAnnouncement = .silently) async {
        guard managesClaudeUpdates else { return }
        // An install in flight owns the state; a background tick must not overwrite it with
        // a stale reading of the same thing.
        guard !claudeUpdateState.isBusy else { return }

        let installed = realClaudeVersion
        discardPreparedIfOvertaken(by: installed)
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
        } catch {
            // Unreachable is not "up to date", but for the schedule it is also not worth a
            // banner: a laptop is offline all the time. Logged, and left for the next tick.
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
        guard let available else {
            // Anything staged describes a build that is no longer newer — usually because it
            // has just been installed.
            if case .ready = claudeUpdateState { claudeUpdateService.discardEverything() }
            publishClaudeUpdateState(.idle)
            announce(
                announcing,
                title: "Claude is up to date",
                message: installed.map { "Claude \($0) is the latest release." }
                    ?? "The installed build is the latest release."
            )
            return
        }
        if case let .ready(verified) = claudeUpdateState, verified.version == available.version {
            announce(
                announcing,
                title: "Claude \(verified.version) is ready to install",
                message: "It has already been downloaded and verified — press Install when "
                    + "you are ready for your profiles to close."
            )
            return // already prepared, nothing to do
        }
        await prepareClaudeUpdate(available)
    }

    /// What a failed check leaves behind, which depends on who asked for it.
    ///
    /// The schedule leaves nothing. A press has to survive being answered, so `.failed` puts
    /// the reason in the banner, the status line and the menu — but **only over `.idle`**.
    /// `.available` and `.ready` each carry a control of their own, Download and Install, and a
    /// build already downloaded and verified stays installable whether or not the feed can be
    /// reached: overwriting that state takes the button away and strands the very bytes the
    /// press was reaching for.
    private func reportFailedCheck(_ error: Error, announcing: ClaudeUpdateAnnouncement) {
        guard announcing.isManual else { return }
        // Cancellation is not a failure to report. Switching the feature off cancels the task
        // mid-request, and while `publishClaudeUpdateState` refuses to speak for a feature that
        // is off, an alert has no such gate — the user would turn the thing off and be told the
        // release service is unreachable.
        guard !Task.isCancelled, managesClaudeUpdates else { return }
        let reason = Self.describeUpdateFailure(error)
        if case .idle = claudeUpdateState { publishClaudeUpdateState(.failed(reason: reason)) }
        announce(
            announcing,
            title: "Could not check for updates",
            message: "Anthropic's release service could not be reached. " + reason
        )
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
    private func publishClaudeUpdateState(_ state: ClaudeUpdateState) {
        guard managesClaudeUpdates, !claudeUpdateState.blocksProfileActivity else { return }
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
    private func prepareClaudeUpdate(_ update: AvailableUpdate) async {
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

    /// Throw away a prepared build that the installed app has caught up with.
    ///
    /// A prepared build records a comparison made when it was fetched. Claude can be updated
    /// after that — by its own updater, by the legacy staged path, or by hand — and then the
    /// waiting build is no longer newer. Left alone, the banner offers it forever (a prepared
    /// state blocks re-checks) and pressing Install closes every profile to swap in something
    /// equal or older: a downgrade dressed as an update.
    private func discardPreparedIfOvertaken(by installed: String?) {
        guard case let .ready(verified) = claudeUpdateState else { return }
        guard !AvailableUpdate.isUpgrade(verified.version, over: installed) else { return }
        Log.claudeUpdate.info(
            "discarding prepared \(verified.version, privacy: .public); no longer newer than installed"
        )
        discardPreparedUpdate()
    }
}

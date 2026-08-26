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
            if newValue {
                startClaudeUpdateRefresh()
            } else {
                // Stop the transfer *first*: a task already inside `prepare` would otherwise
                // finish seconds later and re-stage the build, showing an install banner for
                // a feature that is off.
                claudeUpdateTask?.cancel()
                claudeUpdateTask = nil
                // Then drop several hundred megabytes nothing will ever install. Off the
                // main actor: this deletes an archive and an unpacked Electron bundle —
                // tens of thousands of files — and doing it here would hang the toggle.
                let service = claudeUpdateService
                Task.detached(priority: .utility) { service.discardEverything() }
                setClaudeUpdateState(.idle)
            }
        }
    }

    // MARK: - Checking and preparing

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
        guard managesClaudeUpdates, case .idle = claudeUpdateState else { return }
        let service = claudeUpdateService
        let installed = realClaudeVersion
        Task { @MainActor [weak self] in
            // Off the main actor: re-verifying unpacks and runs `codesign` over an Electron
            // bundle, which is seconds of work.
            let restored = await Task.detached(priority: .utility) {
                service.restorePrepared(newerThan: installed)
            }.value
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
    /// loop that calls this also drives the profile sweep and the legacy auto-apply window —
    /// awaiting a download inside it would stop the clock on both, so a slow connection would
    /// silently eat the nightly apply window.
    ///
    /// The task handle is what makes this single-flight. `UpdateDownloader` states plainly
    /// that overlapping fetches are the caller's to prevent, and two of them would write the
    /// same cache names and race each other's published state.
    func startClaudeUpdateRefresh(now: Date = Date()) {
        guard managesClaudeUpdates, claudeUpdateTask == nil else { return }
        // Stamped when the attempt *starts*: this throttles asking Anthropic, and an attempt
        // that got as far as the network has asked. A failed download is retried by its own
        // state (`.failed` and `.available` both allow a check) rather than by re-asking the
        // feed every minute.
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateCheck)
        claudeUpdateTask = Task { @MainActor [weak self] in
            await self?.refreshClaudeUpdate()
            self?.claudeUpdateTask = nil
        }
    }

    /// Ask the feed, and fetch what it offers.
    ///
    /// Both halves run unattended, and both are safe to: nothing here touches the installed
    /// app or the user's profiles. The bytes land in a cache and the verified bundle waits
    /// beside them until someone presses the button.
    func refreshClaudeUpdate() async {
        guard managesClaudeUpdates else { return }
        // An install in flight owns the state; a background tick must not overwrite it with
        // a stale reading of the same thing.
        guard !claudeUpdateState.isBusy else { return }

        let installed = realClaudeVersion
        discardPreparedIfOvertaken(by: installed)
        let available: AvailableUpdate?
        do {
            available = try await claudeUpdateService.checkForUpdate(installedVersion: installed)
        } catch {
            // Unreachable is not "up to date", but it is also not worth a banner: a laptop
            // is offline all the time. Logged, and left for the next tick.
            Log.claudeUpdate.error("check failed — \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let available else {
            // Anything staged describes a build that is no longer newer — usually because it
            // has just been installed.
            if case .ready = claudeUpdateState { claudeUpdateService.discardEverything() }
            publishClaudeUpdateState(.idle)
            return
        }
        if case let .ready(verified) = claudeUpdateState, verified.version == available.version {
            return // already prepared, nothing to do
        }
        await prepareClaudeUpdate(available)
    }

    /// Publish a state, unless the feature has been switched off in the meantime.
    ///
    /// Cancelling a task does not unwind the work already inside it: `prepare` can be most of
    /// the way through a verification when the toggle goes off, finish a moment later, and
    /// publish `.ready` for a feature that no longer exists. Every transition in this file
    /// goes through here so that cannot happen.
    private func publishClaudeUpdateState(_ state: ClaudeUpdateState) {
        guard managesClaudeUpdates else { return }
        setClaudeUpdateState(state)
    }

    /// Download and verify, reporting progress as it goes.
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

    // MARK: - Installing

    /// Install the prepared build. Closes every profile and reopens the same set.
    ///
    /// Only ever from a press. The swap takes the user's whole working set down for the time
    /// it runs, which is not something to do while they are looking the other way — and
    /// unlike the old staged-update path, nothing here is on a deadline, so there is no
    /// reason to.
    func installClaudeUpdate() async {
        guard case let .ready(verified) = claudeUpdateState else { return }
        // Both paths close every profile and write the same bundle. Until the legacy one is
        // gone, whichever starts first owns the machine.
        guard !isApplyingStagedUpdate else {
            presentInfo(
                title: "Update in progress",
                message: "A staged Claude update is being applied. Wait for it to finish, then try again."
            )
            return
        }
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

    /// Drop the prepared build and everything staged for it, off the main actor.
    ///
    /// Deleting an unpacked Electron bundle is tens of thousands of files; doing it inline
    /// would hang the UI at exactly the moment the user pressed something.
    func discardPreparedUpdate() {
        let service = claudeUpdateService
        Task.detached(priority: .utility) { service.discardEverything() }
        setClaudeUpdateState(.idle)
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

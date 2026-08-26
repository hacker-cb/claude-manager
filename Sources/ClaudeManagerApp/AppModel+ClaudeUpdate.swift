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
            if !newValue {
                // Switching off drops several hundred megabytes that nothing will ever
                // install, and clears a banner offering a version this app is no longer in
                // charge of fetching.
                claudeUpdateService.discardEverything()
                setClaudeUpdateState(.idle)
            }
            Task { await refreshClaudeUpdate() }
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
    func refreshClaudeUpdateIfDue(now: Date = Date()) async {
        guard managesClaudeUpdates else { return }
        guard claudeUpdateState.allowsCheck else { return }
        let last = (defaults.object(forKey: PreferenceKeys.lastClaudeUpdateCheck) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        guard ClaudeUpdateState.isCheckDue(
            lastCheck: last, now: now, interval: Self.claudeUpdateCheckInterval
        ) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.lastClaudeUpdateCheck)
        await refreshClaudeUpdate()
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
            setClaudeUpdateState(.idle)
            return
        }
        if case let .ready(verified) = claudeUpdateState, verified.version == available.version {
            return // already prepared, nothing to do
        }
        await prepareClaudeUpdate(available)
    }

    /// Download and verify, reporting progress as it goes.
    private func prepareClaudeUpdate(_ update: AvailableUpdate) async {
        setClaudeUpdateState(.downloading(version: update.version, received: 0, total: nil))
        do {
            let verified = try await claudeUpdateService.prepare(update) { [weak self] received, total in
                Task { @MainActor in
                    guard let self else { return }
                    // Only while this download is still the thing happening: a cancelled or
                    // superseded transfer must not drag the UI backwards.
                    guard case .downloading = self.claudeUpdateState else { return }
                    self.setClaudeUpdateState(
                        .downloading(version: update.version, received: received, total: total)
                    )
                }
            }
            setClaudeUpdateState(.ready(verified))
        } catch is CancellationError {
            setClaudeUpdateState(.available(update))
        } catch let interrupted as DownloadInterrupted {
            // Resumable and expected on a laptop; the next tick continues where it stopped.
            Log.claudeUpdate.error(
                "download interrupted — \(interrupted.underlying.localizedDescription, privacy: .public)"
            )
            setClaudeUpdateState(.available(update))
        } catch {
            Log.claudeUpdate.error("prepare failed — \(String(describing: error), privacy: .public)")
            setClaudeUpdateState(.failed(reason: Self.describeUpdateFailure(error)))
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
        setClaudeUpdateState(.installing(version: verified.version))
        Log.claudeUpdate.info("installing \(verified.version, privacy: .public)")

        guard let result = await perform({ store in await store.installUpdate(verified) }) else {
            setClaudeUpdateState(.failed(reason: "The update could not be installed."))
            return
        }
        switch result.outcome {
        case let .installed(_, version):
            Log.claudeUpdate.info("installed \(version, privacy: .public)")
            claudeUpdateService.discardEverything()
            setClaudeUpdateState(.idle)
            presentInfo(title: "Claude updated", message: Self.describeInstall(result, version: version))
        case let .instancesStillRunning(names):
            // Not a failure of the update — a profile is busy, and Claude refuses to quit
            // while a session is working. Back to ready so the button is there to try again.
            setClaudeUpdateState(.ready(verified))
            presentInfo(
                title: "Update postponed",
                message: "These profiles would not quit: \(names.joined(separator: ", ")). "
                    + "Claude declines to close while a session is working — finish up and try again."
            )
        case .claudeInstallerRunning:
            setClaudeUpdateState(.ready(verified))
            presentInfo(
                title: "Update postponed",
                message: "Claude's own installer is running. Wait for it to finish, then try again."
            )
        case .couldNotConfirmQuiet:
            setClaudeUpdateState(.ready(verified))
            presentInfo(
                title: "Update postponed",
                message: "Could not confirm every Claude window had closed, so nothing was changed."
            )
        case .differentVolume:
            setClaudeUpdateState(.failed(reason: "The prepared build is on a different volume."))
        case let .swapFailed(reason):
            setClaudeUpdateState(.failed(reason: reason))
        }
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

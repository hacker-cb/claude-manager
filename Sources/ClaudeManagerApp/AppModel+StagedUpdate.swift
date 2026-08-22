import AppKit
import ClaudeManagerCore
import UserNotifications

/// Applying a staged Claude update across every profile, and the once-per-version
/// notification that surfaces it. See `ProfileStore.applyStagedUpdateToAll`.
extension AppModel {
    // MARK: - Persisted staged-update state

    /// Staged versions already surfaced as a notification, so it nags once per version —
    /// **persisted**, since in memory the promise was renewed on every app launch and the
    /// same version nagged again. Written through `defaults`, so tests stay hermetic.
    var notifiedStagedUpdate: Set<String> {
        get { Set(defaults.stringArray(forKey: PreferenceKeys.notifiedStagedUpdate) ?? []) }
        set { defaults.set(Array(newValue), forKey: PreferenceKeys.notifiedStagedUpdate) }
    }

    /// Staged versions whose approaching-forced-restart warning has been posted. Separate
    /// from the above: it is a second notification about the same version, later in its wait.
    var notifiedStagedDeadline: Set<String> {
        get { Set(defaults.stringArray(forKey: PreferenceKeys.notifiedStagedDeadline) ?? []) }
        set { defaults.set(Array(newValue), forKey: PreferenceKeys.notifiedStagedDeadline) }
    }

    /// When the currently-staged version was first seen — the only clock we have on Claude's
    /// own enforcement timer (see `StagedUpdateDeadline`). Stored as a one-entry map keyed by
    /// version, so a newer staged build starts its own wait and the old row is dropped rather
    /// than accumulating one per Claude release.
    var stagedUpdateFirstSeen: [String: Date] {
        get {
            guard let raw = defaults.dictionary(forKey: PreferenceKeys.stagedUpdateFirstSeen)
            else { return [:] }
            return raw.compactMapValues { value in
                guard let seconds = value as? Double else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
        }
        set {
            let raw = newValue.mapValues(\.timeIntervalSince1970)
            defaults.set(raw, forKey: PreferenceKeys.stagedUpdateFirstSeen)
        }
    }

    /// Quit every profile, let ShipIt swap `/Applications/Claude.app`, and relaunch the
    /// set that was open. Single-flight (guarded on `isApplyingStagedUpdate`); a non-success
    /// outcome is surfaced as a notice. Deliberately does *not* pre-guard on `stagedUpdate`:
    /// if it cleared while the confirmation was open (probe blip, or applied elsewhere),
    /// `applyStagedUpdateToAll` re-reads it and returns `.noStagedUpdate`, so the user gets
    /// the "no staged update" notice instead of a silent no-op.
    func applyStagedUpdate() async {
        guard !isApplyingStagedUpdate else { return }
        setApplyingStagedUpdate(true)
        let result = await perform { store in await store.applyStagedUpdateToAll() }
        if let result, let notice = Self.notice(for: result) {
            // `notice` is nil on success, so every message reaching here is a reason the
            // update did not go through — and it has to actually reach the user. The apply
            // closes every profile and can run for minutes, so by the time it reports, the
            // user is in another app. Activating alone is not enough: `RootView` is what
            // presents `currentError`, and Apply can be started from the menu-bar extra with
            // no main window open at all — the alert would then have no host and stay
            // invisible until the window happened to be reopened. So reopen it first (the
            // delegate's closure raises the window *and* activates), falling back to a bare
            // activate only if the binder hasn't run yet.
            if let reopenWindow = AppDelegate.shared?.reopenMainWindow {
                reopenWindow()
            } else {
                NSApp.activate()
            }
            currentError = AppError(title: Self.alertTitle(for: result.outcome), message: notice)
        }
        // The swap replaced /Applications/Claude.app, so re-read its on-disk version first —
        // otherwise the default profile's version display lags a build until the next poll.
        locate()
        // Refresh (which recomputes `stagedUpdate`) *before* clearing the flag, so the
        // Apply affordance isn't re-enabled for a frame with a now-stale staged update.
        await refresh()
        setApplyingStagedUpdate(false)
    }

    /// True — and surfaces a notice — when a launch must be refused because a Claude update
    /// is mid-swap. A new Claude process (default *or* clone; both run the on-disk binary)
    /// launched now would trip ShipIt's zero-instance swap gate or race the relaunch
    /// snapshot. Every launch entry point (`open`, `restart`, `openReal`, deep-link
    /// forwarding) checks this, since the views' launch buttons don't know about the swap.
    ///
    /// Two conditions, because our own flag is not the whole truth: an apply that ends in
    /// `swapStillInstalling` returns with ShipIt **still copying**, and from then on nothing
    /// about our state says so. That is exactly the window where a launch destroys the
    /// install — so the second condition asks the machine whether the installer is alive,
    /// rather than trusting a flag about what *we* are doing.
    /// `async` because the second condition shells out to `pgrep`, and `SystemCommandRunner`
    /// blocks on `Process.waitUntilExit()`. Run inline it would stall the main actor on every
    /// Open, Restart and deep-link forward; every caller here is already `async`, so the probe
    /// goes off-actor and the UI keeps moving.
    func launchBlockedByStagedApply() async -> Bool {
        if isApplyingStagedUpdate {
            currentError = AppError(
                title: "Update in progress",
                message: "A Claude update is being applied to all profiles. "
                    + "Wait for it to finish, then try again."
            )
            return true
        }
        guard await isClaudeInstallerRunning() else { return false }
        currentError = AppError(
            title: "Claude is being updated",
            message: "The installer is still swapping Claude.app. Starting a profile now would "
                + "make it abort and start over — wait for it to finish, then try again."
        )
        return true
    }

    /// Off-actor probe for a live installer. Deliberately not routed through `perform`: that
    /// surfaces an alert when Claude can't be located, and a *guard* must stay silent about
    /// anything but its own reason to refuse.
    private func isClaudeInstallerRunning() async -> Bool {
        guard let real = realClaude, let config = currentConfiguration() else { return false }
        return await Task.detached {
            ProfileStore(realClaude: real, configuration: config).isClaudeInstallerRunning()
        }.value
    }

    /// Record when the current staged version was first seen, and forget everything else.
    ///
    /// This is the only clock available for Claude's enforcement timer, which lives in its
    /// updater's memory: nothing on disk survives a re-arm, since `ShipItState.plist`'s mtime
    /// is rewritten every time the bundle is re-downloaded (observed three times in one
    /// afternoon while the same update kept failing). Never overwritten while a version stays
    /// staged — otherwise the wait would restart on every refresh and the estimate would sit
    /// at zero forever.
    ///
    /// Pruning to the current version is what keeps this a fact rather than a log: it also
    /// clears the two notification ledgers, so a version staged again later — after a
    /// rollback, say — is a fresh wait that may notify again.
    func recordStagedUpdateSighting(now: Date = Date()) {
        let updated = StagedUpdateDeadline.recordSighting(
            of: stagedUpdate?.stagedVersion, into: stagedUpdateFirstSeen, now: now
        )
        guard updated != stagedUpdateFirstSeen else { return } // don't churn defaults per refresh
        stagedUpdateFirstSeen = updated
        // Prune both ledgers to what is still being waited on — that is what lets a version
        // staged again later notify afresh.
        let live = Set(updated.keys)
        notifiedStagedUpdate = notifiedStagedUpdate.intersection(live)
        notifiedStagedDeadline = notifiedStagedDeadline.intersection(live)
    }

    /// The wait and the estimated forced restart for the current staged update, if we have
    /// a first sighting for it.
    var stagedUpdateDeadline: StagedUpdateDeadline? {
        guard let version = stagedUpdate?.stagedVersion,
              let firstSeen = stagedUpdateFirstSeen[version]
        else { return nil }
        return StagedUpdateDeadline(firstSeen: firstSeen)
    }

    /// Warn once, shortly before Claude would restart the default profile by itself.
    ///
    /// The point is to convert a silent 4 am restart into something the user was told about
    /// and could have pre-empted. Deliberately quiet until the window is close: most waits
    /// end within minutes of the user seeing the banner, and a countdown from hour one would
    /// be noise for all of them.
    func notifyStagedDeadlineIfNeeded(now: Date = Date()) async {
        guard let staged = stagedUpdate, let deadline = stagedUpdateDeadline else { return }
        guard deadline.isApproaching(asOf: now, lead: StagedUpdateDeadline.warningLead) else { return }
        guard !notifiedStagedDeadline.contains(staged.stagedVersion) else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let remaining = deadline.remaining(asOf: now)
        let when = remaining <= 0 ? "at any time now" : "in about \(max(1, Int(remaining / 3600))) hours"
        let content = UNMutableNotificationContent()
        content.title = "Claude will restart your default profile \(when)"
        content.body = "Claude \(staged.stagedVersion) has been waiting to install, and Claude "
            + "restarts the default profile on its own to finish. Use “Apply to all profiles” "
            + "to do it at a moment you choose."
        try? await center.add(UNNotificationRequest(
            identifier: "claude-staged-deadline-\(staged.stagedVersion)", content: content, trigger: nil
        ))
        notifiedStagedDeadline.insert(staged.stagedVersion)
    }

    /// Post a local notification once per staged version, so a downloaded-but-blocked
    /// update nags a single time. The record is keyed by version and intentionally never
    /// cleared: a later staged version is a different key, so it notifies afresh, while a
    /// transient nil probe can't re-arm a duplicate for the same version.
    func notifyStagedUpdateIfNeeded() async {
        // Key on the version string, so each staged version nags once. Don't clear the
        // record when the probe is nil: a transient nil (mid-swap, or a slow read) would
        // otherwise re-arm a duplicate notification for the same version.
        guard let staged = stagedUpdate else { return }
        guard !notifiedStagedUpdate.contains(staged.stagedVersion) else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude \(staged.stagedVersion) is ready to install"
        content.body = "The update is downloaded but blocked by open profiles. "
            + "Use “Apply to all profiles.”"
        try? await center.add(UNNotificationRequest(
            identifier: "claude-staged-\(staged.stagedVersion)", content: content, trigger: nil
        ))
        notifiedStagedUpdate.insert(staged.stagedVersion)
    }

    /// Post a local notification for each running launcher newly found to be behind the
    /// on-disk Claude — once per pending version, and only once notifications are actually
    /// authorized, so a permission prompt answered later still fires.
    func notifyClaudeUpdatesIfNeeded() async {
        let behind = profiles.filter(\.claudeUpdateAvailable)
        // Forget skews that resolved (the instance was restarted) so a later update
        // re-notifies; a key is *added* only after its notification is actually posted.
        notifiedClaudeUpdates.formIntersection(Set(behind.map(Self.claudeUpdateKey)))
        let fresh = behind.filter { !notifiedClaudeUpdates.contains(Self.claudeUpdateKey($0)) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        // Not (yet) authorized — leave keys unmarked so a later refresh retries once
        // the user has answered the permission prompt.
        guard status == .authorized || status == .provisional else { return }
        for managed in fresh {
            let content = UNMutableNotificationContent()
            content.title = "\(managed.profile.displayName): restart to update"
            content.body = "Running \(managed.runningClaudeVersion ?? "an older build") — "
                + "Claude \(managed.availableClaudeVersion ?? "") is installed."
            try? await center.add(UNNotificationRequest(
                identifier: "claude-update-\(managed.id)", content: content, trigger: nil
            ))
            notifiedClaudeUpdates.insert(Self.claudeUpdateKey(managed))
        }
    }

    private static func claudeUpdateKey(_ managed: ManagedProfile) -> String {
        "\(managed.id)@\(managed.availableClaudeVersion ?? "")"
    }

    /// Heading for the alert. A swap still in flight is not a failure and must not be
    /// titled like one — the user's profiles are closed on purpose and the install is
    /// going through.
    private static func alertTitle(for outcome: ProfileStore.ApplyStagedUpdateResult.Outcome) -> String {
        if case .swapStillInstalling = outcome { return "Update is still installing" }
        return "Update wasn't applied"
    }

    /// A user-facing notice for a non-success apply, or `nil` when it applied cleanly.
    ///
    /// Each outcome gets the advice that actually fits it. "Click Restart to update to arm
    /// it" belongs to `noStagedUpdate` **only**: telling it to someone whose armed install
    /// merely failed sends them to re-download the whole bundle for nothing.
    private static func notice(for result: ProfileStore.ApplyStagedUpdateResult) -> String? {
        switch result.outcome {
        case .applied:
            return nil
        case .noStagedUpdate:
            return "There is no armed Claude update to apply. If Claude offers a "
                + "“Restart to update” prompt, click it once to arm the install, then apply again."
        case let .instancesStillRunning(names):
            let count = names.count
            return "Couldn't apply the update: \(count) profile\(count == 1 ? "" : "s") wouldn't quit "
                + "(\(names.joined(separator: ", "))). Claude holds a profile open while it is still "
                + "working in a session — finish or stop that work, then try again."
        case let .swapDidNotComplete(version, reason):
            let detail = reason.map { " — \($0)." } ?? "."
            return "Claude \(version) wasn't installed: ShipIt stopped without swapping the app\(detail) "
                + "Your profiles were reopened."
        case let .swapStillInstalling(version):
            return "Claude \(version) is still being installed. Your profiles were left closed so the "
                + "install isn't interrupted — reopen them once it has finished."
        }
    }
}

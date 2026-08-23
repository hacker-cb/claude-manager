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
    /// `surfacingFailures` is false for the unattended pass. The interactive path deliberately
    /// *fights* for attention — it reopens the window and activates the app, because a report
    /// nobody sees is no report. That is exactly wrong at 04:30: a profile vetoing its quit
    /// would foreground Claude Manager with a modal alert while the user is asleep, which is
    /// the same class of surprise this whole feature exists to remove. Unattended failures go
    /// to the log and to Doctor instead, both of which wait to be read.
    func applyStagedUpdate(surfacingFailures: Bool = true) async {
        guard !isApplyingStagedUpdate else { return }
        setApplyingStagedUpdate(true)
        let result = await perform { store in await store.applyStagedUpdateToAll() }
        if let result, let notice = Self.notice(for: result) {
            // `notice` is nil on success, so every message reaching here is a reason the
            // update did not go through — and when a person asked for it, it has to actually
            // reach them. The apply closes every profile and can run for minutes, so by the
            // time it reports, the user is in another app. Activating alone is not enough:
            // `RootView` is what presents `currentError`, and Apply can be started from the
            // menu-bar extra with no main window open at all — the alert would then have no
            // host and stay invisible until the window happened to be reopened. So reopen it
            // first (the delegate's closure raises the window *and* activates), falling back
            // to a bare activate only if the binder hasn't run yet.
            if surfacingFailures {
                if let reopenWindow = AppDelegate.shared?.reopenMainWindow {
                    reopenWindow()
                } else {
                    NSApp.activate()
                }
                currentError = AppError(title: Self.alertTitle(for: result.outcome), message: notice)
            } else {
                Log.autoApply.info("unattended apply did not complete: \(notice, privacy: .public)")
                // One outcome can't be left to the log alone. `swapStillInstalling` leaves
                // every profile **closed** on purpose — reopening would abort the install —
                // and nothing reopens them afterwards. Unattended, that means waking up to an
                // empty desk with no explanation, while the setting promised the profiles
                // would come back. A notification is the right weight for it: it waits to be
                // read instead of seizing the screen at 04:30, but it does not vanish.
                if case .swapStillInstalling = result.outcome {
                    await notifyProfilesLeftClosed(notice: notice)
                }
            }
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
    /// clears the two notification ledgers, so a *different* version staged later is a fresh
    /// wait that may notify again. A *nil* probe changes nothing, and neither does the same
    /// version re-staged — see the prune below and `StagedUpdateDeadline.recordSighting`.
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
        // Same rule for the offer's answers, with the same limit the ledgers above have: the
        // prune only runs when a *different* version is staged, because a nil probe
        // deliberately preserves the record (`StagedUpdateDeadline.recordSighting`) and the
        // guard above returns early when nothing changed. So a version answered, installed,
        // and later re-staged unchanged keeps that answer. That is the price of not resetting
        // on a transient nil, and it errs toward asking too little rather than too often.
        answeredAutoApplyOffer = answeredAutoApplyOffer.intersection(live)
    }

    /// The wait and the estimated forced restart for the current staged update, if we have
    /// a first sighting for it.
    ///
    /// The enforcement window is read from the **default profile's** managed-config overlay
    /// rather than assumed: a deployment that lowered `autoUpdaterEnforcementHours` to 8 h
    /// would otherwise get an estimate silent until hour 68, long past the restart it was
    /// supposed to predict. Absent (or under MDM, where this tier isn't what Claude reads)
    /// falls back to Claude's documented default.
    var stagedUpdateDeadline: StagedUpdateDeadline? {
        guard let version = stagedUpdate?.stagedVersion,
              let firstSeen = stagedUpdateFirstSeen[version]
        else { return nil }
        let hours = currentConfiguration().flatMap { config in
            ManagedConfigWriter(managedPreferencesURLs: config.managedPreferencesURLs).integer(
                ProfileManagedConfig.autoUpdaterEnforcementHoursKey,
                userDataPath: config.defaultProfileUserDataPath
            )
        }
        return StagedUpdateDeadline(
            firstSeen: firstSeen,
            enforcementHours: hours.map(Double.init) ?? StagedUpdateDeadline.defaultEnforcementHours
        )
    }

    /// Warn once, shortly before Claude would restart the default profile by itself.
    ///
    /// The point is to convert a silent 4 am restart into something the user was told about
    /// and could have pre-empted. Deliberately quiet until the window is close: most waits
    /// end within minutes of the user seeing the banner, and a countdown from hour one would
    /// be noise for all of them.
    ///
    /// **Scheduled, not polled.** Every other notification here fires from `refresh()`, which
    /// the monitor drives once a minute *only while `NSApp.isActive`* — a deliberate choice so
    /// a backgrounded menu-bar app doesn't spawn `ps` forever. But this warning's whole job is
    /// to arrive during a 72-hour wait the user spends elsewhere, and a login launch or a
    /// closed window means the app may never be frontmost in that entire window: checked
    /// inline, it would simply never fire. So the notification is handed to
    /// `UNTimeIntervalNotificationTrigger` at sighting time and the system delivers it whether
    /// or not we are running — and `cancelStagedDeadlineWarning` withdraws it if the update
    /// lands first.
    func notifyStagedDeadlineIfNeeded(now: Date = Date()) async {
        guard let staged = stagedUpdate, let deadline = stagedUpdateDeadline else {
            await cancelStagedDeadlineWarnings()
            return
        }
        // Withdraw any warning still pending for a *different* version. Pruning the ledger
        // isn't enough: v1's request carries its own identifier, so replacing v1 with v2
        // leaves v1's trigger armed and it fires later about a version long gone.
        await cancelStagedDeadlineWarnings(except: staged.stagedVersion)
        guard !notifiedStagedDeadline.contains(staged.stagedVersion) else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        // Fire `warningLead` before the estimate — or as good as immediately when the window
        // is already that close (a trigger interval must be > 0).
        let untilWarning = deadline.remaining(asOf: now) - StagedUpdateDeadline.warningLead
        let fireAfter = max(1, untilWarning)
        let hoursAtFire = max(1, Int(StagedUpdateDeadline.warningLead / 3600))
        let when = untilWarning <= 0
            ? "soon"
            : "in about \(hoursAtFire) hour\(hoursAtFire == 1 ? "" : "s")"
        let content = UNMutableNotificationContent()
        // Conditional on purpose. This is scheduled hours ahead and delivered by the system,
        // so it can arrive when the premise no longer holds: if every profile happened to
        // close while Claude Manager was shut down, ShipIt would have installed the update
        // and there is nothing left running to withdraw the request. A notification that
        // *asserts* an imminent restart would then simply be wrong, so it states the
        // condition it was scheduled under instead.
        content.title = "Claude may restart your default profile \(when)"
        content.body = "If Claude \(staged.stagedVersion) is still waiting to install, Claude "
            + "restarts the default profile on its own to finish. Use “Apply to all profiles” "
            + "to do it at a moment you choose."
        do {
            try await center.add(UNNotificationRequest(
                identifier: Self.deadlineNotificationID(for: staged.stagedVersion),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireAfter, repeats: false)
            ))
        } catch {
            // Record it only once it is actually scheduled. The ledger is persisted, so a
            // swallowed failure here would retire the warning permanently — no retry on the
            // next refresh, and none after a restart either.
            return
        }
        notifiedStagedDeadline.insert(staged.stagedVersion)
    }

    /// Tell the user their profiles were left closed, and why — the one unattended outcome
    /// that changes what they see when they sit down, rather than merely failing to change
    /// anything. Delivered immediately (no trigger): the fact is already true.
    private func notifyProfilesLeftClosed(notice: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your profiles are closed — Claude is still installing"
        content.body = notice
        try? await center.add(UNNotificationRequest(
            identifier: "claude-profiles-left-closed", content: content, trigger: nil
        ))
    }

    /// Shared by the scheduler and the withdrawal below. One definition, because the two
    /// have to agree: a prefix that drifts leaves a pending notification nothing can cancel,
    /// which then fires hours later about an update that already landed.
    static let deadlineNotificationPrefix = "claude-staged-deadline-"

    /// Identifier for a version's scheduled deadline warning.
    static func deadlineNotificationID(for version: String) -> String {
        deadlineNotificationPrefix + version
    }

    /// Withdraw any scheduled deadline warning that is no longer true.
    ///
    /// Necessary because the warning is scheduled *ahead of time*: once the update applies —
    /// or the staged version changes — a pending trigger would still fire hours later,
    /// announcing a restart for an update that already happened. Withdrawal is by identifier
    /// over the pending set, so it also clears one left by a previous run of the app.
    /// `keeping` names the version whose warning is still true — everything else pending is
    /// withdrawn. Passing `nil` (nothing staged) withdraws all of them.
    func cancelStagedDeadlineWarnings(except keeping: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let keepID = keeping.map(Self.deadlineNotificationID(for:))
        let stale = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.deadlineNotificationPrefix) && $0 != keepID }
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        // Drop the ledger entries the withdrawal invalidated, so those versions could warn
        // again if they were ever staged anew — but keep the one still armed.
        notifiedStagedDeadline = notifiedStagedDeadline.intersection(Set(keeping.map { [$0] } ?? []))
    }

    /// Post a local notification once per staged version, so a downloaded-but-blocked
    /// update nags a single time. Keyed by version, so a later staged version notifies
    /// afresh — `recordStagedUpdateSighting` replaces the record (and prunes this ledger)
    /// when a *different* version is staged. A nil probe deliberately changes nothing; see
    /// `StagedUpdateDeadline.recordSighting`.
    func notifyStagedUpdateIfNeeded() async {
        guard let staged = stagedUpdate else { return }
        guard !notifiedStagedUpdate.contains(staged.stagedVersion) else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude \(staged.stagedVersion) is ready to install"
        content.body = "The update is downloaded but blocked by open profiles. "
            + "Use “Apply to all profiles.”"
        do {
            try await center.add(UNNotificationRequest(
                identifier: "claude-staged-\(staged.stagedVersion)", content: content, trigger: nil
            ))
        } catch {
            // Same reason as the deadline warning: now that the ledger is persisted, marking
            // a failed post as delivered would silence this version for good.
            return
        }
        notifiedStagedUpdate.insert(staged.stagedVersion)
    }

    /// Post a local notification for each running launcher newly found to be behind the
    /// on-disk Claude — once per pending version, and only once notifications are actually
    /// authorized, so a permission prompt answered later still fires.
    func notifyClaudeUpdatesIfNeeded() async {
        let behind = profiles.filter(\.claudeUpdateAvailable)
        // Forget skews that resolved (the instance was restarted) so a later update
        // re-notifies; a key is *added* only after its notification is actually posted.
        // Assign only on a real change: this is `UserDefaults`-backed now, so an unconditional
        // read-modify-write would churn the file on every refresh tick.
        let live = notifiedClaudeUpdates.intersection(Set(behind.map(Self.claudeUpdateKey)))
        if live != notifiedClaudeUpdates { notifiedClaudeUpdates = live }
        let fresh = behind.filter { !notifiedClaudeUpdates.contains(Self.claudeUpdateKey($0)) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        // Not (yet) authorized — leave keys unmarked so a later refresh retries once
        // the user has answered the permission prompt.
        guard status == .authorized || status == .provisional else { return }
        // Collected, then written once: `notifiedClaudeUpdates` is `UserDefaults`-backed, so
        // inserting per profile inside the loop is a read-modify-write of the whole set for
        // each notification posted.
        var delivered: Set<String> = []
        for managed in fresh {
            let content = UNMutableNotificationContent()
            content.title = "\(managed.profile.displayName): restart to update"
            content.body = "Running \(managed.runningClaudeVersion ?? "an older build") — "
                + "Claude \(managed.availableClaudeVersion ?? "") is installed."
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "claude-update-\(managed.id)", content: content, trigger: nil
                ))
            } catch {
                // Now that this ledger is persisted, marking a failed post as delivered would
                // silence that profile's "restart to update" for good — the same reason the
                // two ledgers above record only after a successful `add`.
                continue
            }
            delivered.insert(Self.claudeUpdateKey(managed))
        }
        if !delivered.isEmpty { notifiedClaudeUpdates.formUnion(delivered) }
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

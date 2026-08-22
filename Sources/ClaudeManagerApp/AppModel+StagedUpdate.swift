import AppKit
import ClaudeManagerCore
import UserNotifications

/// Applying a staged Claude update across every profile, and the once-per-version
/// notification that surfaces it. See `ProfileStore.applyStagedUpdateToAll`.
extension AppModel {
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
            // update did not go through. Bring the app forward with it: the apply closes
            // every profile and can run for minutes, so by the time it reports the user is
            // long since in another app — an alert left behind a window nobody is looking at
            // is a report that never arrives.
            NSApp.activate()
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

    /// True — and surfaces a notice — when a launch must be refused because a staged-update
    /// apply is mid-swap. A new Claude process (default *or* clone; both run the on-disk
    /// binary) launched now would trip ShipIt's zero-instance swap gate or race the
    /// relaunch snapshot. Every launch entry point (`open`, `restart`, `openReal`, deep-link
    /// forwarding) checks this, since the views' launch buttons don't know about the swap.
    func launchBlockedByStagedApply() -> Bool {
        guard isApplyingStagedUpdate else { return false }
        currentError = AppError(
            title: "Update in progress",
            message: "A Claude update is being applied to all profiles. "
                + "Wait for it to finish, then try again."
        )
        return true
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

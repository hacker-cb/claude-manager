import ClaudeManagerCore
import UserNotifications

/// Applying a staged Claude update across every account, and the once-per-version
/// notification that surfaces it. See `ProfileStore.applyStagedUpdateToAll`.
extension AppModel {
    /// Quit every account, let ShipIt swap `/Applications/Claude.app`, and relaunch the
    /// set that was open. Single-flight (the button and the guard both key on
    /// `isApplyingStagedUpdate`); a non-success outcome is surfaced as a notice.
    func applyStagedUpdate() async {
        guard !isApplyingStagedUpdate, stagedUpdate != nil else { return }
        setApplyingStagedUpdate(true)
        let result = await perform { store in await store.applyStagedUpdateToAll() }
        if let result, let notice = Self.notice(for: result) {
            currentError = AppError(message: notice)
        }
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
            message: "A Claude update is being applied to all accounts. "
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
        content.body = "The update is downloaded but blocked by open accounts. "
            + "Use “Apply update to all accounts.”"
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

    /// A user-facing notice for a non-success apply, or `nil` when it applied cleanly.
    private static func notice(for result: ProfileStore.ApplyStagedUpdateResult) -> String? {
        switch result.outcome {
        case .applied:
            return nil
        case .noStagedUpdate:
            return "There is no staged Claude update to apply."
        case let .instancesStillRunning(names):
            let count = names.count
            return "Couldn't apply the update: \(count) account\(count == 1 ? "" : "s") wouldn't quit "
                + "gracefully. Quit \(count == 1 ? "it" : "them") manually, then try again."
        case let .swapTimedOut(version):
            return "Claude \(version) is downloaded but not armed to install. Click a "
                + "“Restart to update” prompt once to arm it, then apply again. "
                + "Your accounts were reopened."
        }
    }
}

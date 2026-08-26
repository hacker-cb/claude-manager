import ClaudeManagerCore
import Foundation
import UserNotifications

/// Telling the user that a **running** profile is older than the Claude on disk.
///
/// Nothing to do with how Claude gets updated: a profile keeps running the bundle it started
/// with, so after any install — this app's, Claude's own, or a hand-dragged one — the open
/// profiles are still on the previous build until they are restarted, and this is the only
/// cue that says so.
///
/// It outlived the staged-update machinery it used to live beside for exactly that reason.
/// Everything else in that file existed to wait on Squirrel; this describes a fact about
/// processes.
extension AppModel {
    /// Withdraw notifications scheduled by a previous release whose controls no longer exist.
    ///
    /// The staged-update path scheduled two kinds — "Claude X is ready to install" and the
    /// forced-restart deadline warning — and the deadline one was a *timed* request, so an
    /// upgrade can carry a pending notification that fires days later telling the user to
    /// press "Apply to all profiles". That button is gone. Cheap, idempotent, and run once at
    /// startup: identifiers are matched by prefix because they carried the version.
    func withdrawRetiredUpdateNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let retired = pending
                .map(\.identifier)
                .filter { $0.hasPrefix("claude-staged-") }
            guard !retired.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: retired)
            center.removeDeliveredNotifications(withIdentifiers: retired)
            Log.claudeUpdate.info(
                "withdrew \(retired.count, privacy: .public) notification(s) from the retired update path"
            )
        }
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
                // This ledger is persisted, so marking a failed post as delivered would silence
                // that profile's "restart to update" for good.
                continue
            }
            delivered.insert(Self.claudeUpdateKey(managed))
        }
        if !delivered.isEmpty { notifiedClaudeUpdates.formUnion(delivered) }
    }

    private static func claudeUpdateKey(_ managed: ManagedProfile) -> String {
        "\(managed.id)@\(managed.availableClaudeVersion ?? "")"
    }
}

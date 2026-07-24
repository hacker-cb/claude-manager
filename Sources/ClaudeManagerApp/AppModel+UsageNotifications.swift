import ClaudeManagerCore
import Foundation
import UserNotifications

/// Limit-approaching reminders: evaluate each fresh snapshot, dedup against the persisted ledger
/// (so each threshold fires once per reset window, surviving relaunches), and post the single
/// most-severe warning per limit. All off when notifications are disabled.
extension AppModel {
    func notifyLimits(for accounts: [AccountUsage]) async {
        guard usageTrackingEnabled, usageNotificationsEnabled else { return }
        let evaluator = LimitEvaluator()
        let now = Date()
        for account in accounts {
            // Re-checked each account: this suspends on every `add`/ledger call, and the user can
            // flip the master switch (or notifications) off on the same actor during a suspension.
            // "Off stops all notifications" (Settings copy, SECURITY.md) has to hold for the
            // accounts this loop hasn't reached yet, not only the ones before the toggle.
            guard usageTrackingEnabled, usageNotificationsEnabled else { return }
            guard case .fresh = account.state, let snapshot = account.snapshot else { continue }
            for warning in evaluator.warnings(for: snapshot, now: now) {
                await notifyIfNew(warning, account: account, now: now)
            }
        }
    }

    private func notifyIfNew(_ warning: UsageWarning, account: AccountUsage, now: Date) async {
        let uuid = account.identity.uuid
        let already = await usageHistory.wasNotified(
            accountUUID: uuid, limitKey: warning.limitKey,
            threshold: warning.threshold, resetsAt: warning.resetsAt
        )
        guard !already else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(accountDisplayName(for: account)) — \(warning.limitLabel) limit"
        var body = "You've used \(UsageFormat.percent(warning.utilization)) of your \(warning.limitLabel) limit"
        if let resets = UsageFormat.resets(warning.resetsAt, now: now) { body += " · \(resets)" }
        content.body = body
        content.sound = warning.severity == .critical ? .default : nil

        // One request per (account, limit, threshold, reset) so re-posts coalesce, not stack.
        let identifier = "usage.\(uuid).\(warning.limitKey).\(warning.threshold).\(warning.resetsAt?.timeIntervalSince1970 ?? 0)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Delivery failed — most plausibly authorization hasn't been granted yet, since it is
            // requested fire-and-forget at launch and a poll can finish first. Leave the ledger
            // untouched so a later pass retries: recording it first meant one undelivered alert
            // marked that threshold delivered for the whole reset window, permanently.
            return
        }
        await usageHistory.markNotified(
            accountUUID: uuid, limitKey: warning.limitKey,
            threshold: warning.threshold, resetsAt: warning.resetsAt, notifiedAt: now
        )
    }

    /// A human name for the row: the default profile, else a bound profile's display name, else
    /// the Claude login's own label (email / display name), falling back to "Claude account".
    func accountDisplayName(for account: AccountUsage) -> String {
        if account.bindingIDs.contains(TokenBinding.defaultID) { return "Default profile" }
        for id in account.bindingIDs {
            if let managed = profiles.first(where: { $0.profile.id == id }) {
                return managed.profile.displayName
            }
        }
        return account.identity.accountLabel ?? "Claude account"
    }
}

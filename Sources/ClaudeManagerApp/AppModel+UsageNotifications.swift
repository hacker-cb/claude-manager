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
        // Named from the **published** entry, not this pass's raw account. `result.accounts` carries
        // only the bindings that resolved, so a login whose second profile merely could not be read
        // looks like a one-profile account here — and the title reverts to that profile's name for a
        // quota both of them draw on, while the panes beside it say "shared with 2 profiles". The
        // fold is where membership is settled; this reads its answer.
        let published = account.bindingIDs.compactMap { usageByBinding[$0] }.first ?? account
        content.title = "\(accountDisplayName(for: published)) — \(warning.limitLabel) limit"
        var body = "You've used \(UsageFormat.percent(warning.utilization)) of your \(warning.limitLabel) limit"
        if let resets = UsageFormat.resets(warning.resetsAt, now: now) { body += " · \(resets)" }
        content.body = body
        content.sound = warning.severity == .critical ? .default : nil

        // One request per (account, limit, threshold, reset) so re-posts coalesce, not stack.
        // Bucket the reset exactly as the ledger does, so the server's sub-second jitter in
        // `resets_at` can't mint a fresh identifier each poll (which would stack, not coalesce).
        let resetsBucket = UsageHistoryStore.resetBucketMillis(warning.resetsAt)
        let identifier = "usage.\(uuid).\(warning.limitKey).\(warning.threshold).\(resetsBucket)"
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

    /// What to call an account in a notification title or the Doctor inspector. The rule lives in
    /// core (`UsagePresentation.accountName`) and is tested there; this supplies the one thing core
    /// cannot know — what each binding is called on screen.
    func accountDisplayName(for account: AccountUsage) -> String {
        UsagePresentation.accountName(account, profileNames: profileNames)
    }

    /// Binding id → the name the UI shows for it.
    private var profileNames: [String: String] {
        var names = [TokenBinding.defaultID: "Default profile"]
        for managed in profiles {
            names[managed.profile.id] = managed.profile.displayName
        }
        return names
    }
}

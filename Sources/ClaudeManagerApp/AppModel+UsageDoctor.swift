import ClaudeManagerCore
import Foundation

/// Usage-tracking Doctor support: a live-state diagnostic and the raw-response inspector loader.
/// Kept app-side (not in core `doctor()`) because both read the published usage state, not the
/// on-disk profile store.
extension AppModel {
    /// One Usage line for Doctor, or nil when tracking is off / there's nothing actionable to say.
    /// Surfaces the two states the user can act on: keychain access not yet granted, and an
    /// account whose token expired. Otherwise a plain "active" when at least one account is fresh.
    func usageDoctorDiagnostic() -> Diagnostic? {
        guard usageTrackingEnabled else { return nil }
        let accounts = Array(usageByBinding.values)
        let anyFresh = accounts.contains { $0.state == .fresh }

        if !anyFresh, keychainAccessBlocked(accounts) {
            return Diagnostic(
                severity: .warning,
                title: "Usage tracking needs keychain access",
                detail: "Claude Manager couldn't read an account token from your keychain. Click "
                    + "Refresh in the menu bar and choose \u{201C}Always Allow\u{201D} when macOS asks."
            )
        }
        if accounts.contains(where: { $0.state == .loginNeeded }) {
            return Diagnostic(
                severity: .warning,
                title: "An account needs to sign in again",
                detail: "A token has expired or was rejected. Open the account, sign in, then Refresh."
            )
        }
        return anyFresh ? Diagnostic(severity: .ok, title: "Usage tracking is active") : nil
    }

    /// True when a keychain read is the thing standing between us and usage data — a `noSource`
    /// account or an explicit `keychainUnavailable` binding failure.
    private func keychainAccessBlocked(_ accounts: [AccountUsage]) -> Bool {
        if accounts.contains(where: { $0.state == .noSource }) { return true }
        return usageBindingFailures.values.contains { failure in
            if case .keychainUnavailable = failure { return true }
            return false
        }
    }

    /// One row of the raw-response inspector: an account and its latest stored `/usage` body.
    struct UsageInspectorEntry: Identifiable {
        let id: String // account uuid
        let name: String
        let rawJSON: String?
    }

    /// The latest raw `/usage` JSON per unique account, for the Doctor inspector. Deduped by
    /// account uuid (shared profiles collapse to one), named for display, sorted by name.
    func loadUsageInspectorEntries() async -> [UsageInspectorEntry] {
        var seen = Set<String>()
        var uniqueAccounts: [AccountUsage] = []
        for account in usageByBinding.values where seen.insert(account.identity.uuid).inserted {
            uniqueAccounts.append(account)
        }
        var entries: [UsageInspectorEntry] = []
        for account in uniqueAccounts {
            let raw = await usageHistory.latestRawJSON(accountUUID: account.identity.uuid)
            entries.append(UsageInspectorEntry(
                id: account.identity.uuid,
                name: accountDisplayName(for: account),
                rawJSON: raw
            ))
        }
        return entries.sorted { $0.name < $1.name }
    }
}

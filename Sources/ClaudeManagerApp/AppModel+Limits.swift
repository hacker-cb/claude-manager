import ClaudeManagerCore
import Foundation

/// The Limits page's wiring: the accounts it ranks, the ranking itself, the damping state that
/// keeps the answer steady, and the history the timeline draws.
///
/// Nothing here decides anything — `UsageOverview` does, in the core, under tests. This layer
/// supplies the two facts the core cannot know headless: which bindings the fleet currently has,
/// and what the user calls them.
extension AppModel {
    /// How far back the timeline reads, and how coarsely.
    ///
    /// A week each way is what the page draws, and an hour is finer than the fastest poll
    /// (the adaptive lane is five minutes, so an hour still folds several samples), which keeps
    /// the decode cost to a couple of hundred points per account however long the history is.
    static let limitsHistoryWindow: TimeInterval = 7 * 24 * 3600
    static let limitsHistoryStep: TimeInterval = 3600

    // MARK: - What is being ranked

    /// The bindings that still exist. Under "Manually only" polling
    /// `refreshUsageIfBindingsChanged` fetches nothing, so every map keyed by binding —
    /// `usageByBinding`, `usageBindingFailures` — keeps a launcher the user removed until the
    /// next pass, which may never come.
    ///
    /// The default binding is always in the set, and not because `profileEntries` lists it:
    /// that row disappears while Claude.app cannot be located — during an update's bundle swap,
    /// or after the app is moved — whereas `usageBindings` fetches and stores the default
    /// account's usage regardless. Deriving the set from the rows alone dropped that account from
    /// the ranking exactly when the missing-Claude banner was already on screen, taking the menu
    /// rows and the timeline with it on a single-profile setup.
    var liveBindingIDs: Set<String> {
        Set(profileEntries.map(\.id)).union([TokenBinding.defaultID])
    }

    // One entry per Claude account, not per profile.
    //
    // `usageByBinding` is keyed by binding, so a login shared by three launchers appears three
    // times; ranking that list would recommend the same account three times over and let it
    // crowd out every other. `UsagePresentation.onePerAccount` already folds it — and folds it
    // *stably*, which matters here because the ranking is re-run on every tick.

    var limitsAccounts: [AccountUsage] {
        // Filtered **before** the fold, and the fan-out trimmed with it. Filtering afterwards
        // left a removed binding eligible to represent its login — `onePerAccount` picks the
        // widest fan-out, and a deleted entry still carries its old sibling list — so the board
        // could rank an account on the deleted entry's state while opening a surviving profile.
        let live = liveBindingIDs
        var scoped: [String: AccountUsage] = [:]
        for (binding, usage) in usageByBinding where live.contains(binding) {
            var trimmed = usage
            trimmed.bindingIDs = usage.bindingIDs.filter(live.contains)
            scoped[binding] = trimmed
        }
        return UsagePresentation.onePerAccount(scoped)
    }

    /// The worst window across the ranked fleet, for the sidebar row's subtitle.
    ///
    /// Read from `limitsAccounts` rather than `menuBarUsageSummary`, which walks every binding in
    /// the map: the row labels the page, and the two disagreed the moment one of them filtered a
    /// removed launcher out and the other did not.
    ///
    /// On exactly the accounts whose snapshots the ranking reads, for the same reason: narrowed
    /// to `.fresh`, a laptop going offline flipped every account to `.stale` and left the row
    /// falling through to "where to work now" as though nothing had ever been read — while
    /// clicking it showed a full board of bars and percentages from those very snapshots.
    /// Two things the compact form has to carry that a bare percentage cannot. A window whose own
    /// reset has **passed** is no claim about anything current — the ranking stops measuring
    /// against it — and the row would otherwise advertise last week's 100% indefinitely. And a
    /// figure from an account that is not `.fresh` is dated, for the reason every other surface
    /// on this page dates one.
    var limitsWorstSummary: String? {
        let now = Date()
        let live = limitsAccounts
            .filter { !UsageOverview.needsUser($0.state) }
            .compactMap { account -> (account: AccountUsage, limit: UsageLimit)? in
                guard let limit = account.snapshot?.bindingLimit else { return nil }
                if let resetsAt = limit.resetsAt, resetsAt <= now { return nil }
                return (account, limit)
            }
        guard let worst = live.max(by: { $0.limit.utilization < $1.limit.utilization })
        else { return nil }
        let summary = UsageFormat.limitSummary(worst.limit)
        guard worst.account.state != .fresh,
              let capturedAt = worst.account.snapshot?.capturedAt else { return summary }
        return "\(summary) · as of \(UsageFormat.age(capturedAt, now: now))"
    }

    /// What each binding is called, for naming an account after a profile where the login has no
    /// name of its own. The only thing in this file the core could not work out for itself.
    var limitsProfileNames: [String: String] {
        var names = [TokenBinding.defaultID: "Default profile"]
        for managed in profiles {
            names[managed.profile.id] = managed.profile.displayName
        }
        return names
    }

    /// The ranking for one mode. A pure read: the damping state it uses was settled by the last
    /// usage pass, so calling this from a view body — once a minute, per surface — decides
    /// nothing and writes nothing.
    func limitsOverview(mode: WorkMode, now: Date = Date()) -> UsageOverview {
        UsageOverview.rank(
            accounts: limitsAccounts,
            mode: mode,
            previousLeader: limitsLeaders[mode],
            now: now
        )
    }

    /// Whether the two modes can differ — the page shows one answer rather than a toggle between
    /// two identical ones when they cannot.
    var limitsHasScopedWindows: Bool {
        UsageOverview.hasScopedWindows(in: limitsAccounts)
    }

    /// What to call a mode, from the models the fleet actually reports.
    func limitsModeLabel(_ mode: WorkMode) -> String {
        UsageOverview.modeLabel(mode, accounts: limitsAccounts)
    }

    /// What to call an account: its login, or the profile that best speaks for it.
    func limitsAccountName(_ account: AccountUsage) -> String {
        UsagePresentation.accountName(account, profileNames: limitsProfileNames)
    }

    /// The profiles on an account, in the order the sidebar lists them — what the answer card's
    /// Open button acts on, and what it offers a choice between when a login has several.
    func limitsProfiles(of account: AccountUsage) -> [ProfileEntry] {
        let ids = Set(account.bindingIDs)
        return profileEntries.filter { ids.contains($0.id) }
    }

    /// What a binding that produced no account needs from the user, one sentence per distinct
    /// remedy, in a stable order.
    ///
    /// A fleet where every profile is signed out or has never been opened resolves no account at
    /// all, so the page has nothing to rank — and telling that user to Refresh sends them back to
    /// the same screen, since refreshing cannot sign anyone in. `UsagePresentation` already owns
    /// the wording for each cause.
    var limitsBlockingFailures: [String] {
        // Live bindings only, for the reason `limitsAccounts` filters: this map is stale in
        // exactly the same way, and an unfiltered read told the user to sign into a profile they
        // had already deleted.
        let live = liveBindingIDs
        var seen = Set<String>()
        return usageBindingFailures.keys.sorted()
            .filter(live.contains)
            .compactMap { usageBindingFailures[$0] }
            .compactMap { UsagePresentation.sentence(usage: nil, failure: $0)?.text }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Keeping the answer steady

    /// Record what each mode recommends now, so the next pass can damp a near-equal challenger.
    ///
    /// Called once per usage pass rather than from a view: a ranking that updated its own damping
    /// state as a side effect of being *drawn* would settle differently depending on how often
    /// the window was open.
    func refreshLimitsLeaders(now: Date = Date()) {
        var leaders: [WorkMode: String] = [:]
        for mode in WorkMode.allCases {
            // Deliberately re-ranked with the *existing* leader in hand: that is what lets a
            // standing recommendation survive a challenger inside the margin.
            leaders[mode] = limitsOverview(mode: mode, now: now).leader?.id
        }
        setLimitsLeaders(leaders)
    }

    // MARK: - The timeline's history

    /// Load each ranked account's thinned history for the timeline.
    ///
    /// Off the main actor by construction — `UsageHistoryStore` is an actor and every call here
    /// suspends — so a fleet's worth of SQL never blocks a frame. Accounts are read one after the
    /// other on purpose: they share a single serialized connection, so asking concurrently buys
    /// nothing and only lengthens the actor's queue.
    ///
    /// **Generation-guarded, and the guard is not decoration.** Two callers reach this — the
    /// page's `.task` and the poll — so without one the slower of two overlapping loads
    /// overwrites the fresher, wholesale. And the master switch can flip *between* two of those
    /// reads: the entry guard has already passed by then, so the disable path clears
    /// `limitsSeries` and this method would fetch the rest of the fleet from `usage.db` and put
    /// it back. "Off reads nothing, stores nothing" is checked before every read and again before
    /// the publish, the way `refreshUsage` does it one layer up.
    func loadLimitsSeries(now: Date = Date()) async {
        guard usageTrackingEnabled else {
            setLimitsSeries([:])
            return
        }
        limitsSeriesGeneration += 1
        let generation = limitsSeriesGeneration
        let since = now.addingTimeInterval(-Self.limitsHistoryWindow)
        var loaded: [String: [UsageSeriesPoint]] = [:]
        for account in limitsAccounts {
            guard usageTrackingEnabled, generation == limitsSeriesGeneration else { return }
            loaded[account.identity.uuid] = await usageHistory.series(
                accountUUID: account.identity.uuid,
                since: since,
                step: Self.limitsHistoryStep
            )
        }
        guard usageTrackingEnabled, generation == limitsSeriesGeneration else { return }
        setLimitsSeries(loaded)
    }
}

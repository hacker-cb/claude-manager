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

    /// One entry per Claude account, not per profile.
    ///
    /// `usageByBinding` is keyed by binding, so a login shared by three launchers appears three
    /// times; ranking that list would recommend the same account three times over and let it
    /// crowd out every other. `UsagePresentation.onePerAccount` already folds it — and folds it
    /// *stably*, which matters here because the ranking is re-run on every tick.
    var limitsAccounts: [AccountUsage] {
        UsagePresentation.onePerAccount(usageByBinding)
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
    func loadLimitsSeries(now: Date = Date()) async {
        guard usageTrackingEnabled else {
            setLimitsSeries([:])
            return
        }
        let since = now.addingTimeInterval(-Self.limitsHistoryWindow)
        var loaded: [String: [UsageSeriesPoint]] = [:]
        for account in limitsAccounts {
            loaded[account.identity.uuid] = await usageHistory.series(
                accountUUID: account.identity.uuid,
                since: since,
                step: Self.limitsHistoryStep
            )
        }
        setLimitsSeries(loaded)
    }
}

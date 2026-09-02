import Foundation

/// The ranking itself: assessing one account, ordering the set, and damping the answer.
/// Split from the types in `UsageOverview.swift` the way the rest of the core splits a service
/// from its slices — the file-length gate is enforced (`swiftlint --strict`), and the two halves
/// are read for different reasons.
extension UsageOverview {
    // MARK: - One account

    /// Assess a single account against the windows `mode` counts.
    ///
    /// The order of the guards is the rule: a binding that needs a person is not a budget
    /// question at all, an account with nothing read yet cannot be assessed, and only then do
    /// the gates and the headroom apply.
    static func assess(_ account: AccountUsage, mode: WorkMode, now: Date) -> UsageCandidate {
        if needsUser(account.state) {
            return UsageCandidate(
                account: account,
                state: .needsAttention,
                headroom: nil,
                bindingWeekly: nil,
                weeklyResetsAt: nil,
                gatingLimit: nil,
                freesAt: nil,
                canLead: false
            )
        }
        guard let snapshot = account.snapshot else {
            return UsageCandidate(
                account: account,
                state: .noData,
                headroom: nil,
                bindingWeekly: nil,
                weeklyResetsAt: nil,
                gatingLimit: nil,
                freesAt: nil,
                canLead: false
            )
        }
        let counted = countedLimits(in: snapshot, mode: mode)
        let bound = bind(weekly: countedWeekly(in: snapshot, mode: mode), now: now)
        if let gate = gate(among: counted) {
            return UsageCandidate(
                account: account,
                state: gate.state,
                headroom: nil,
                bindingWeekly: bound?.limit,
                weeklyResetsAt: bound?.resetsAt,
                gatingLimit: gate.limit,
                // Only a reset still ahead is a return time; a passed one is unknown, not early.
                freesAt: gate.limit.resetsAt.flatMap { $0 > now ? $0 : nil },
                canLead: false
            )
        }
        let headroom = bound?.headroom
        return UsageCandidate(
            account: account,
            state: state(forHeadroom: headroom),
            headroom: headroom,
            bindingWeekly: bound?.limit,
            weeklyResetsAt: bound?.resetsAt,
            gatingLimit: nil,
            freesAt: nil,
            // A stale, offline or rate-limited account still shows its last figures, but it may
            // not *instruct*: those numbers stopped moving, and the work they would send someone
            // to may already have been done against them. Nor may one with no clock behind it.
            canLead: account.state == .fresh && headroom != nil
        )
    }

    /// Whether this state means the binding is waiting on a person rather than on a window.
    /// Exhaustive on purpose — a future case must be classified here, not defaulted.
    private static func needsUser(_ state: UsageState) -> Bool {
        switch state {
        case .loginNeeded, .noSource: true
        case .fresh, .stale, .rateLimited, .offline: false
        }
    }

    // MARK: - Which windows count

    /// Every window `mode` takes into account — the gates read this.
    ///
    /// A window whose `kind` this build does not recognize is **kept**, for the same reason the
    /// parser keeps it: it may be the one that actually constrains the account. It counts as a
    /// gate only (below), never toward headroom, because nothing here knows how long its window
    /// is or whether the mode should have counted it at all.
    static func countedLimits(in snapshot: UsageSnapshot, mode: WorkMode) -> [UsageLimit] {
        snapshot.limits.filter { counts($0, mode: mode) }
    }

    /// The counted windows whose budget is a *weekly* one — the only ones headroom is measured
    /// over, since the headroom formula compares a budget against a week of wall clock.
    static func countedWeekly(in snapshot: UsageSnapshot, mode: WorkMode) -> [UsageLimit] {
        snapshot.limits.filter { ($0.isWeeklyAll || $0.isWeeklyScoped) && counts($0, mode: mode) }
    }

    private static func counts(_ limit: UsageLimit, mode: WorkMode) -> Bool {
        guard limit.isWeeklyScoped else { return true }
        return mode == .scopedModel
    }

    // MARK: - Gates

    /// The window that takes this account out of the running, and what to call that.
    ///
    /// **What counts as a gate is `displaySeverity`, not a percentage.** That is the same
    /// reading every bar in the app paints from, so it folds in the server's own `severity`
    /// alongside our threshold — and the server escalates for things a flat percentage cannot
    /// express: a plan policy, an account restriction, a window kind this build has no model
    /// for. Gating on utilization alone let the ranking recommend an account whose bar the rest
    /// of the app was already drawing red, which is precisely the promise this gate exists to
    /// keep. It also stops the 0.90 threshold being restated here.
    ///
    /// **The window reported is the one that blocks longest, not the fullest.** A 95% session
    /// freeing in fifteen minutes beside a 94% week freeing in three days is not a
    /// fifteen-minute wait, and quoting the session's countdown there promises a return the week
    /// will not honour. The *state* still names the most severe thing — an exhausted window is
    /// `out` whatever else is happening.
    static func gate(among limits: [UsageLimit]) -> (state: CandidateState, limit: UsageLimit)? {
        let gating = limits.filter { $0.displaySeverity == .critical }
        guard let blocker = blocksLongest(gating) else { return nil }
        if gating.contains(where: { $0.utilization >= 1 }) { return (.out, blocker) }
        // The 5-hour window is a gate and nothing more: it refills within hours, so it must not
        // sink an account the way a spent week does, and it never enters the headroom below.
        // Sending someone to a different profile every time a session fills would cost them a
        // chat's context for a wait measured in minutes — but only while it is the *one* thing
        // gating, or the row would offer a wait of minutes over a block of days.
        return (gating.allSatisfy(\.isSession) ? .sessionNearlyFull : .nearlyOut, blocker)
    }

    /// Of several gating windows, the one that keeps the account unusable longest — because that
    /// is when work can go there again.
    ///
    /// A window that reported no reset blocks longest of all: nothing said it frees, so nothing
    /// may promise it does. Fully ordered (reset, then utilization, then the window's own
    /// identity) so the row a reader sees does not depend on the order the server listed them in.
    static func blocksLongest(_ limits: [UsageLimit]) -> UsageLimit? {
        limits.min { lhs, rhs in
            if lhs.resetsAt != rhs.resetsAt {
                guard let left = lhs.resetsAt else { return true }
                guard let right = rhs.resetsAt else { return false }
                return left > right
            }
            if lhs.utilization != rhs.utilization { return lhs.utilization > rhs.utilization }
            // `dedupKey`, not `rawKind`: two scoped windows share a kind and differ only by
            // model, so a rawKind tie left the named blocker — and the model label the reader
            // sees — decided by the order the server happened to list them in.
            return lhs.dedupKey < rhs.dedupKey
        }
    }

    // MARK: - Headroom

    /// The weekly window that actually constrains the account, the clock it was measured
    /// against, and the headroom that came out.
    struct WeeklyBinding {
        var limit: UsageLimit
        var resetsAt: Date?
        var headroom: Double?
    }

    /// Bind to the **tightest** weekly window, measuring each against its own deadline.
    ///
    /// Not the highest utilization, which is only the same thing while every weekly window
    /// resets at the same moment. They are separate fields on separate windows — a fleet here
    /// reports two that differ — and once they diverge the fuller window can easily be the freer
    /// one: 70% resetting tomorrow leaves more room than 60% with six days to spend it in.
    /// Picking by percentage there reports the account as on pace while the window that will
    /// actually stop it goes unmentioned.
    ///
    /// **A window whose reset has passed is not measured at all.** Clamping a negative remainder
    /// to zero turned a spent quota into maximal headroom and left the row able to lead — and a
    /// `.fresh` snapshot can sit well past its reset, which is the documented state of a
    /// "Manually only" fleet and of any account re-served inside the poll floor. The figures
    /// from a window that has since rolled over say nothing about the one now running, so they
    /// earn no pace claim until a refresh. The same rule the panes apply to a countdown.
    ///
    /// With nothing measurable the fullest window is still reported, so the row keeps a figure —
    /// it simply carries no headroom, and `assess` will not let it lead.
    static func bind(weekly: [UsageLimit], now: Date) -> WeeklyBinding? {
        // An inactive scoped window legitimately reports no reset while the week it belongs to
        // plainly has one; only a reset still ahead can stand in for it.
        let fallback = weekly.compactMap(\.resetsAt).filter { $0 > now }.min()
        let measured: [WeeklyBinding] = weekly.compactMap { limit in
            guard let resetsAt = limit.resetsAt ?? fallback, resetsAt > now else { return nil }
            let weekRemaining = (resetsAt.timeIntervalSince(now) / LimitEvaluator.sevenDayWindow)
                .clamped(to: 0 ... 1)
            return WeeklyBinding(
                limit: limit,
                resetsAt: resetsAt,
                headroom: (1 - limit.utilization) - weekRemaining
            )
        }
        if let tightest = measured.min(by: tighter) { return tightest }
        return weekly
            .max { $0.utilization < $1.utilization }
            .map { WeeklyBinding(limit: $0, resetsAt: nil, headroom: nil) }
    }

    /// "lhs constrains more than rhs" — least headroom first, then the fuller window, then the
    /// earlier reset, then the window's own identity.
    ///
    /// Everything after the first key exists so a reordered payload cannot change which window a
    /// row names: equal headroom does not mean equal labels, percentages or reset times, and
    /// `bindingWeekly` is what the reader is shown.
    static func tighter(_ lhs: WeeklyBinding, _ rhs: WeeklyBinding) -> Bool {
        let left = lhs.headroom ?? .greatestFiniteMagnitude
        let right = rhs.headroom ?? .greatestFiniteMagnitude
        if left != right { return left < right }
        if lhs.limit.utilization != rhs.limit.utilization {
            return lhs.limit.utilization > rhs.limit.utilization
        }
        if lhs.resetsAt != rhs.resetsAt {
            guard let leftReset = lhs.resetsAt else { return false }
            guard let rightReset = rhs.resetsAt else { return true }
            return leftReset < rightReset
        }
        return lhs.limit.dedupKey < rhs.limit.dedupKey
    }

    private static func state(forHeadroom headroom: Double?) -> CandidateState {
        // No clock, so no pace claim: say the account is unremarkable rather than praising or
        // faulting a rate nothing measured.
        guard let headroom else { return .onPace }
        if headroom >= spendThreshold { return .spend }
        if headroom >= paceThreshold { return .onPace }
        return .burningFast
    }

    // MARK: - Ordering

    /// Sort order. Lanes first (a spent week is not comparable with a healthy one), then within
    /// the usable lane: current figures ahead of stale ones, then the most headroom. Gated lanes
    /// are ordered by how soon they free up, which is the only useful thing left to say about
    /// them. The uuid is the final tiebreak so the sequence is stable between passes.
    static func precedes(_ lhs: UsageCandidate, _ rhs: UsageCandidate) -> Bool {
        if lhs.state.order != rhs.state.order { return lhs.state.order < rhs.state.order }
        if lhs.state.isUsable {
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let left = lhs.headroom ?? -.greatestFiniteMagnitude
            let right = rhs.headroom ?? -.greatestFiniteMagnitude
            if left != right { return left > right }
        } else if lhs.freesAt != rhs.freesAt {
            // Nil is ordered explicitly, not skipped. Comparing two dates *only when both sides
            // carried one* and otherwise falling through to the uuid is not a weak ordering at
            // all: with `z` freeing in 1h, `a` in 2h and `m` reporting no reset, `z < a`,
            // `a < m` and `m < z` all hold at once. `sorted(by:)` does not merely order a cycle
            // oddly — its result is undefined. A window that never said when it frees sorts
            // last, which is also the honest place for it.
            guard let left = lhs.freesAt else { return false }
            guard let right = rhs.freesAt else { return true }
            return left < right
        }
        return lhs.id < rhs.id
    }

    // MARK: - Stickiness

    /// Keep the standing leader in front unless a challenger genuinely beats it.
    ///
    /// Applies only while the held account could still lead: one that has hit a gate loses the
    /// place outright, however narrow the margin, because the point of the damping is to avoid
    /// churn between equals — not to keep recommending somewhere work cannot go.
    static func applyStickiness(
        _ ordered: [UsageCandidate],
        previousLeader: String?
    ) -> [UsageCandidate] {
        guard let previousLeader,
              let top = ordered.first, top.canLead, top.id != previousLeader,
              let index = ordered.firstIndex(where: { $0.id == previousLeader }),
              ordered[index].canLead,
              let held = ordered[index].headroom,
              let challenger = top.headroom,
              challenger - held < stickyMargin
        else { return ordered }
        var kept = ordered
        kept.insert(kept.remove(at: index), at: 0)
        return kept
    }
}

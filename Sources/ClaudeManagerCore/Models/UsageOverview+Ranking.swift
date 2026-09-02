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
                gatingLimit: nil,
                canLead: false
            )
        }
        guard let snapshot = account.snapshot else {
            return UsageCandidate(
                account: account,
                state: .noData,
                headroom: nil,
                bindingWeekly: nil,
                gatingLimit: nil,
                canLead: false
            )
        }
        let counted = countedLimits(in: snapshot, mode: mode)
        let weekly = countedWeekly(in: snapshot, mode: mode)
        let binding = weekly.max { $0.utilization < $1.utilization }
        if let gate = gate(among: counted) {
            return UsageCandidate(
                account: account,
                state: gate.state,
                headroom: nil,
                bindingWeekly: binding,
                gatingLimit: gate.limit,
                canLead: false
            )
        }
        let headroom = headroom(binding: binding, weekly: weekly, now: now)
        return UsageCandidate(
            account: account,
            state: state(forHeadroom: headroom),
            headroom: headroom,
            bindingWeekly: binding,
            gatingLimit: nil,
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
    /// Exhaustion wins over nearly-exhausted, and among equals the highest utilization is
    /// reported — the reader wants the window that is actually stopping them, not whichever the
    /// server happened to list first.
    static func gate(among limits: [UsageLimit]) -> (state: CandidateState, limit: UsageLimit)? {
        let ranked = limits.sorted { $0.utilization > $1.utilization }
        if let full = ranked.first(where: { $0.utilization >= 1 }) {
            return (.out, full)
        }
        guard let hot = ranked.first(where: { $0.utilization >= UsageLimit.criticalUtilization })
        else { return nil }
        // The 5-hour window is a gate and nothing more: it refills within hours, so it must not
        // sink an account the way a spent week does, and it never enters the headroom below.
        // Sending someone to a different profile every time a session fills would cost them a
        // chat's context for a wait measured in minutes.
        return (hot.isSession ? .sessionNearlyFull : .nearlyOut, hot)
    }

    // MARK: - Headroom

    /// Unspent share of the binding window minus the share of the week still to run.
    ///
    /// Nil when nothing counted reported a reset: with no clock there is no pace to compare a
    /// budget against, and a number invented for that case would rank an account we know least
    /// about above ones we can actually reason over.
    static func headroom(binding: UsageLimit?, weekly: [UsageLimit], now: Date) -> Double? {
        guard let binding else { return nil }
        // The binding window's own reset first; a sibling weekly window's only as a fallback,
        // since an inactive scoped window legitimately reports none.
        guard let resetsAt = binding.resetsAt ?? weekly.compactMap(\.resetsAt).min() else {
            return nil
        }
        let weekRemaining = (resetsAt.timeIntervalSince(now) / LimitEvaluator.sevenDayWindow)
            .clamped(to: 0 ... 1)
        return (1 - binding.utilization) - weekRemaining
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
        } else if let left = lhs.freesAt, let right = rhs.freesAt, left != right {
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

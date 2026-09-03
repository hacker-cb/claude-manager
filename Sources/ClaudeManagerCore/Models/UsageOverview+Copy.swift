import Foundation

/// What a surface *says* about a ranking — decided here, for the same reason
/// `UsagePresentation` exists: the Limits page and the menu-bar rows answer one question, and
/// two copies of the wording drift into two different answers to it.
///
/// Locale-free and clock-relative throughout, which is what keeps it in the core where tests can
/// reach it. Absolute times ("resets Thu 10:59") need a locale, so they stay in the app layer's
/// `UsageFormat.resets` and are appended there by whichever surface has room for them.
public extension UsageOverview {
    // MARK: - Naming the mode

    /// Every per-model weekly window the fleet actually reports, in a stable order.
    ///
    /// Read from the snapshots rather than assumed: the model behind a scoped window is data,
    /// and this is what lets the mode toggle name it without the name being compiled in.
    ///
    /// Only accounts the ranking actually reads, on the same rule `hasScopedWindows` applies: a
    /// login-needed binding keeps its last snapshot, so an old `7d·Opus` window on it made the
    /// mode call itself "Fable / Opus work" while nothing rankable reported Opus at all.
    static func scopedModelNames(in accounts: [AccountUsage]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for account in accounts where !needsUser(account.state) {
            for limit in account.snapshot?.weeklyScoped ?? [] {
                guard let name = limit.scopeModelName, !name.isEmpty, seen.insert(name).inserted
                else { continue }
                names.append(name)
            }
        }
        return names.sorted()
    }

    /// Whether the two modes can differ at all. On a plan that reports no scoped window, both
    /// count exactly the same windows — so a surface should show one answer, not a toggle
    /// between two identical ones.
    ///
    /// Only accounts whose snapshot the ranking actually reads count. A binding that needs a
    /// person keeps its last snapshot, but `assess` answers `.needsAttention` before looking at
    /// it, so its scoped windows cannot move either ranking — and where such an account was the
    /// only one carrying them, the toggle offered a choice between two identical answers.
    static func hasScopedWindows(in accounts: [AccountUsage]) -> Bool {
        accounts.contains { account in
            guard !needsUser(account.state) else { return false }
            return !(account.snapshot?.weeklyScoped ?? []).isEmpty
        }
    }

    /// What to call a mode: the reported model names for the scoped one ("Fable work"), and
    /// "Other work" for its complement.
    ///
    /// Where the fleet reports **no** per-model window, both modes count the same windows and
    /// neither name is true of what is on screen: "Other work" has nothing to be other than, and
    /// "Per-model work" promises a window that does not exist. That case is one answer about all
    /// of someone's work, and says so — it is also the shape a surface falls into by default,
    /// since the stored mode is the scoped one and the toggle that would change it is hidden.
    static func modeLabel(_ mode: WorkMode, accounts: [AccountUsage]) -> String {
        guard hasScopedWindows(in: accounts) else { return "All work" }
        guard mode == .scopedModel else { return "Other work" }
        let names = scopedModelNames(in: accounts)
        // Scoped windows exist here — `hasScopedWindows` just said so — but none reported a model
        // name. "All work" would be the wrong half of a contradictory pair: this mode counts
        // *more* windows than its sibling, which is still labelled "Other work".
        guard !names.isEmpty else { return "Per-model work" }
        return "\(names.joined(separator: " / ")) work"
    }

    // MARK: - Naming a state

    /// The two or three words a chip prints for a candidate.
    ///
    /// Its ranking position where the figures are current, and the **account's own condition**
    /// where they are not. A `.stale`, `.offline` or `.rateLimited` account keeps its last
    /// snapshot, so `assess` still gives it a budget state — and a chip reading "Use it or lose
    /// it" over figures that stopped moving yesterday is advice, dimmed or not. `canLead` already
    /// refuses such a candidate the lead; this is that same fact where someone reads it.
    static func stateLabel(for candidate: UsageCandidate, now: Date = Date()) -> String {
        guard !candidate.isCurrent else { return stateLabel(candidate.state) }
        switch candidate.state {
        // Already the account's own condition rather than a position in the ranking.
        case .needsAttention: return stateLabel(candidate.state)
        // `.noData` is *not* one of those, which is easy to read the wrong way round: a first
        // pass that never got a snapshot lands here whether nothing was asked or the network was
        // down, and "Not checked yet" over an offline account states the one thing that is not
        // true. It keeps that label only where the account really is `.fresh` — which the guard
        // above has already sent home.
        default: return condition(candidate.account, now: now)
        }
    }

    /// The short form of what is wrong with an account's figures — the chip's width, where
    /// `UsagePresentation.stateNote` gives the sentence.
    private static func condition(_ account: AccountUsage, now: Date) -> String {
        switch account.state {
        case let .stale(since): "As of \(UsageFormat.age(since, now: now))"
        case .rateLimited: "Rate limited"
        case .offline: "Offline"
        // `needsUser` sends both of these to `.needsAttention`, which never reaches here.
        case .fresh, .loginNeeded, .noSource: stateLabel(.needsAttention)
        }
    }

    /// The two or three words a chip prints for a candidate's position.
    static func stateLabel(_ state: CandidateState) -> String {
        switch state {
        case .spend: "Use it or lose it"
        case .onPace: "On pace"
        case .burningFast: "Burning fast"
        case .paceUnknown: "Pace unknown"
        case .sessionNearlyFull: "Session nearly full"
        case .nearlyOut: "Nearly out"
        case .out: "Out"
        case .needsAttention: "Needs you"
        case .noData: "Not checked yet"
        }
    }

    // MARK: - The sentence

    /// One line saying why a candidate is where it is — the figure that decided it, and when
    /// that figure changes.
    ///
    /// A candidate needing a person defers to `UsagePresentation`, which already owns that
    /// vocabulary for the sidebar and the detail pane; saying it a second way here would put two
    /// different remedies for one condition on two surfaces of the same app.
    static func reason(for candidate: UsageCandidate, now: Date) -> String {
        switch candidate.state {
        case .needsAttention:
            return UsagePresentation.stateNote(candidate.account, now: now)
        case .noData:
            // `.offline` and `.rateLimited` reach this state too, on a first pass that never got
            // a snapshot — and `UsagePresentation` can name either. Only a genuinely `.fresh`
            // binding with nothing stored has no reason to give beyond the absence itself.
            guard candidate.account.state == .fresh else {
                return UsagePresentation.stateNote(candidate.account, now: now)
            }
            return "no usage read yet"
        case .out, .nearlyOut, .sessionNearlyFull:
            guard candidate.isCurrent else {
                return datedFigure(for: candidate, limit: candidate.gatingLimit, now: now)
            }
            return gatedReason(for: candidate, now: now)
        case .spend, .onPace, .burningFast, .paceUnknown:
            guard candidate.isCurrent else {
                return datedFigure(for: candidate, limit: candidate.bindingWeekly, now: now)
            }
            return budgetReason(for: candidate, now: now)
        }
    }

    /// What is left to say about an account whose figures stopped moving: the last one read, and
    /// when it was read.
    ///
    /// The verdict is what goes — "on pace", "burning fast", "back in 2h" are all claims about a
    /// window as it stands *now*, and this account has not reported since. The figure survives
    /// because it is still a fact, correctly dated; the reset survives too, in the list's own
    /// column, which reads it from the window rather than from a pace.
    private static func datedFigure(
        for candidate: UsageCandidate, limit: UsageLimit?, now: Date
    ) -> String {
        let note = dated(UsagePresentation.stateNote(candidate.account, now: now), candidate, now)
        guard let limit else { return note }
        return "\(limit.shortLabel) \(UsageFormat.percent(limit.utilization)) · \(note)"
    }

    /// The age of the figures, where saying what is wrong has not already given it.
    ///
    /// `.stale` carries its own "as of …"; `.offline` and `.rateLimited` do not, and a snapshot is
    /// retained under those indefinitely — so "7d 60% · offline" was a percentage with no date on
    /// it at all, which is the one thing this sentence exists to supply. `headerNote` dates them
    /// the same way, for the same reason.
    private static func dated(_ note: String, _ candidate: UsageCandidate, _ now: Date) -> String {
        switch candidate.account.state {
        case .offline, .rateLimited:
            guard let capturedAt = candidate.account.snapshot?.capturedAt else { return note }
            return "\(note) · as of \(UsageFormat.age(capturedAt, now: now))"
        case .fresh, .stale, .loginNeeded, .noSource:
            return note
        }
    }

    private static func gatedReason(for candidate: UsageCandidate, now: Date) -> String {
        guard let limit = candidate.gatingLimit else { return stateLabel(candidate.state) }
        let figure = "\(limit.shortLabel) \(UsageFormat.percent(limit.utilization))"
        // Re-checked against the *rendering* clock, not only the ranking one: a row built before
        // a reset and drawn after it would otherwise say "back in now" for ever, since
        // `compactDuration` floors a negative interval. `budgetReason` already asks this.
        guard UsagePresentation.showsReset(candidate.freesAt, now: now),
              let freesAt = candidate.freesAt else { return figure }
        // The verb follows the window actually named, not the row's state. The state is the most
        // severe thing happening while the figure is the window that blocks longest, and those
        // are not always one window — "back in 1h" beside a 95% session read as a claim about
        // that session being spent.
        let verb = limit.utilization >= 1 ? "back" : "frees"
        return "\(figure) · \(verb) in \(UsageFormat.compactDuration(freesAt.timeIntervalSince(now)))"
    }

    private static func budgetReason(for candidate: UsageCandidate, now: Date) -> String {
        guard let limit = candidate.bindingWeekly else { return stateLabel(candidate.state) }
        let left = UsageFormat.percent(1 - limit.utilization)
        let head = "\(left) of \(limit.shortLabel) left"
        // The reset the pace was actually measured against. Re-deriving it here is what let the
        // countdown fall out of exactly the rows whose claim depends on it, leaving a confident
        // "use it or lose it" with nothing saying when.
        guard UsagePresentation.showsReset(candidate.weeklyResetsAt, now: now),
              let resetsAt = candidate.weeklyResetsAt else { return head }
        let clock = UsageFormat.compactDuration(resetsAt.timeIntervalSince(now))
        switch candidate.state {
        // The whole reason this ranking exists: a weekly window's leftovers do not roll over, so
        // a budget running ahead of its clock is spent now or not at all.
        case .spend: return "\(head) · resets in \(clock) — unused budget is gone at reset"
        case .burningFast: return "\(head) · \(clock) to go — burning faster than the week"
        default: return "\(head) · \(clock) to go — on pace"
        }
        // `paceUnknown` never reaches the switch: it exists precisely because no reset was
        // usable, and the guard above returns the bare figure for it.
    }
}

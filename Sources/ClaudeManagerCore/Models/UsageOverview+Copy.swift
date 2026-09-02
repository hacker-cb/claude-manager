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
    static func scopedModelNames(in accounts: [AccountUsage]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for account in accounts {
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
    static func hasScopedWindows(in accounts: [AccountUsage]) -> Bool {
        !accounts.allSatisfy { ($0.snapshot?.weeklyScoped ?? []).isEmpty }
    }

    /// What to call a mode: the reported model names for the scoped one ("Fable work"), and
    /// "Other work" for its complement. Falls back to a neutral phrase where nothing has
    /// reported a name yet, rather than printing a placeholder that reads like a model.
    static func modeLabel(_ mode: WorkMode, accounts: [AccountUsage]) -> String {
        guard mode == .scopedModel else { return "Other work" }
        let names = scopedModelNames(in: accounts)
        guard !names.isEmpty else { return "Per-model work" }
        return "\(names.joined(separator: " / ")) work"
    }

    // MARK: - Naming a state

    /// The two or three words a chip prints for a candidate's position.
    static func stateLabel(_ state: CandidateState) -> String {
        switch state {
        case .spend: "Use it or lose it"
        case .onPace: "On pace"
        case .burningFast: "Burning fast"
        case .paceUnknown: "No reset reported"
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
            UsagePresentation.stateNote(candidate.account, now: now)
        case .noData:
            "no usage read yet"
        case .out, .nearlyOut, .sessionNearlyFull:
            gatedReason(for: candidate, now: now)
        case .spend, .onPace, .burningFast, .paceUnknown:
            budgetReason(for: candidate, now: now)
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
        // The reset the pace was actually measured against, not the binding window's own field:
        // a scoped window that reported none still belongs to a week, and reading only its own
        // field dropped the countdown from exactly the rows whose claim depends on it — leaving
        // a confident "use it or lose it" with nothing saying when.
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

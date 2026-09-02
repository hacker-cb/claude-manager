import Foundation
import Testing
@testable import ClaudeManagerCore

/// The ranking rule: which windows count, what gates an account, how headroom orders the rest,
/// and what may become the answer. The copy that dresses these up is asserted in
/// `UsageOverviewCopyTests`.
struct UsageOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    /// Half of a seven-day window, so `weekRemaining` is exactly 0.5 and every headroom below
    /// reads as `(1 - utilization) - 0.5` — the arithmetic stays visible in the test.
    private var halfWeek: TimeInterval {
        LimitEvaluator.sevenDayWindow / 2
    }

    // MARK: - Builders

    private func limit(
        _ kind: String,
        _ utilization: Double,
        resetsIn: TimeInterval? = nil,
        model: String? = nil
    ) -> UsageLimit {
        UsageLimit(
            rawKind: kind,
            utilization: utilization,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            isActive: true,
            scopeModelName: model
        )
    }

    private func account(
        _ uuid: String,
        limits: [UsageLimit],
        state: UsageState = .fresh
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid, email: "\(uuid)@example.com"),
            snapshot: UsageSnapshot(limits: limits, capturedAt: now),
            state: state,
            bindingIDs: [uuid]
        )
    }

    /// An account whose only counted budget is the all-models week, at `utilization`, resetting
    /// half a week out — so its headroom is `(1 - utilization) - 0.5`.
    private func weeklyAccount(
        _ uuid: String,
        _ utilization: Double,
        state: UsageState = .fresh
    ) -> AccountUsage {
        account(
            uuid,
            limits: [limit(UsageLimit.kindWeeklyAll, utilization, resetsIn: halfWeek)],
            state: state
        )
    }

    /// Headroom is a difference of two binary fractions, so it is compared with a tolerance —
    /// `(1 - 0.3) - 0.5` is 0.19999999999999996, not 0.2. The tolerance is far tighter than
    /// anything the states or `stickyMargin` distinguish.
    private func isClose(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    private func rank(
        _ accounts: [AccountUsage],
        mode: WorkMode = .scopedModel,
        previousLeader: String? = nil
    ) -> UsageOverview {
        UsageOverview.rank(accounts: accounts, mode: mode, previousLeader: previousLeader, now: now)
    }

    // MARK: - Headroom decides the usable states

    @Test
    func headroomIsBudgetMinusTimeRemaining() {
        let overview = rank([weeklyAccount("a", 0.2)])
        // 80% of the window left, half the week still to run.
        #expect(isClose(overview.candidates.first?.headroom, 0.30))
        #expect(overview.candidates.first?.state == .spend)
    }

    @Test
    func theSpendThresholdSitsAtATwentyPointLead() {
        // Pinned from either side rather than on the threshold itself: at exactly 0.20 the two
        // states differ by one word and nothing a reader could act on, and the arithmetic that
        // produces headroom cannot land on it exactly anyway.
        #expect(rank([weeklyAccount("a", 0.29)]).candidates.first?.state == .spend)
        #expect(rank([weeklyAccount("a", 0.31)]).candidates.first?.state == .onPace)
    }

    @Test
    func levelBudgetIsOnPace() {
        // (1 - 0.5) - 0.5 == 0 — spending at exactly the rate the week elapses.
        #expect(rank([weeklyAccount("a", 0.5)]).candidates.first?.state == .onPace)
    }

    @Test
    func thePaceThresholdSitsAtATenPointDeficit() {
        #expect(rank([weeklyAccount("a", 0.59)]).candidates.first?.state == .onPace)
        #expect(rank([weeklyAccount("a", 0.61)]).candidates.first?.state == .burningFast)
    }

    @Test
    func burningFasterThanTheWeek() {
        // (1 - 0.7) - 0.5 == -0.20.
        #expect(rank([weeklyAccount("a", 0.7)]).candidates.first?.state == .burningFast)
    }

    @Test
    func mostHeadroomLeads() {
        let overview = rank([weeklyAccount("low", 0.7), weeklyAccount("high", 0.2)])
        #expect(overview.candidates.map(\.id) == ["high", "low"])
        #expect(overview.leader?.id == "high")
    }

    // MARK: - What the mode counts

    @Test
    func scopedWindowCountsOnlyInScopedMode() {
        let hot = account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.98, resetsIn: halfWeek, model: "Fable")
        ])
        #expect(rank([hot], mode: .scopedModel).candidates.first?.state == .nearlyOut)
        // The same account is a fine place for work that never touches that model.
        let other = rank([hot], mode: .otherWork).candidates.first
        #expect(other?.state == .spend)
        #expect(other?.bindingWeekly?.isWeeklyAll == true)
    }

    @Test
    func scopedWindowBindsWhenItIsTheHigherOne() {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.6, resetsIn: halfWeek, model: "Fable")
        ])])
        #expect(overview.candidates.first?.bindingWeekly?.scopeModelName == "Fable")
        #expect(isClose(overview.candidates.first?.headroom, -0.10))
    }

    // MARK: - Windows this build does not recognize

    @Test
    func unknownWindowGatesButNeverEntersHeadroom() {
        // Forward-compatibility, matching the parser: a window we cannot classify may still be
        // the thing stopping the user, so it gates — but nothing here knows how long its period
        // is, so it must not be measured against a week.
        let gated = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit("quantum_flux", 0.99, resetsIn: 3600)
        ])])
        #expect(gated.candidates.first?.state == .nearlyOut)
        #expect(gated.candidates.first?.gatingLimit?.rawKind == "quantum_flux")

        let ungated = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek),
            limit("quantum_flux", 0.80, resetsIn: 3600)
        ])])
        #expect(isClose(ungated.candidates.first?.headroom, 0.30))
        #expect(ungated.candidates.first?.bindingWeekly?.isWeeklyAll == true)
    }

    // MARK: - Only current figures may instruct

    @Test
    func staleFiguresRankBehindFreshOnesAndNeverLead() {
        let overview = rank([
            weeklyAccount("stale", 0.1, state: .stale(since: now)),
            weeklyAccount("fresh", 0.6)
        ])
        // The stale account has far more headroom and still comes second.
        #expect(overview.candidates.map(\.id) == ["fresh", "stale"])
        #expect(overview.leader?.id == "fresh")
        #expect(overview.candidates.last?.canLead == false)
    }

    @Test
    func aFleetWithNoCurrentFiguresRecommendsNobody() {
        let overview = rank([
            weeklyAccount("a", 0.1, state: .offline),
            weeklyAccount("b", 0.2, state: .rateLimited)
        ])
        #expect(overview.leader == nil)
        // ...but the rows are still ordered and still carry their figures.
        #expect(overview.candidates.count == 2)
        #expect(isClose(overview.candidates.first?.headroom, 0.40))
    }

    @Test
    func aBindingNeedingAPersonSinksBelowEveryWindowProblem() {
        let overview = rank([
            account("signedOut", limits: [], state: .noSource(.signedOut)),
            account("out", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 3600)]),
            weeklyAccount("fine", 0.2)
        ])
        #expect(overview.candidates.map(\.id) == ["fine", "out", "signedOut"])
        #expect(overview.candidates[2].state == .needsAttention)
    }

    @Test
    func loginNeededIsAlsoAPersonProblem() {
        let overview = rank([account("a", limits: [], state: .loginNeeded)])
        #expect(overview.candidates.first?.state == .needsAttention)
        #expect(overview.leader == nil)
    }

    @Test
    func anAccountWithNoSnapshotSaysSoRatherThanRankingLast() {
        let bare = AccountUsage(
            identity: AccountIdentity(uuid: "bare"),
            snapshot: nil,
            state: .fresh,
            bindingIDs: ["bare"]
        )
        let overview = rank([bare, weeklyAccount("fine", 0.2)])
        #expect(overview.candidates.map(\.id) == ["fine", "bare"])
        #expect(overview.candidates.last?.state == .noData)
    }

    // MARK: - Which weekly window binds

    @Test
    func theTightestWeeklyWindowBindsNotTheFullestOne() {
        // The two are the same thing only while both windows reset together. Once the dates
        // diverge the fuller window can be the freer one, and picking by percentage reports an
        // account as on pace while the window that will actually stop it goes unmentioned.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.70, resetsIn: 24 * 3600),
            limit(UsageLimit.kindWeeklyScoped, 0.60, resetsIn: 6 * 24 * 3600, model: "Fable")
        ])])
        let candidate = overview.candidates.first
        // 60% with six days left is far tighter than 70% resetting tomorrow.
        #expect(candidate?.bindingWeekly?.scopeModelName == "Fable")
        #expect(isClose(candidate?.headroom, 0.40 - 6.0 / 7.0))
        #expect(candidate?.state == .burningFast)
        #expect(candidate?.weeklyResetsAt == now.addingTimeInterval(6 * 24 * 3600))
    }

    @Test
    func aWindowWhoseResetHasPassedEarnsNoPaceClaim() {
        // A `.fresh` snapshot can sit past its own reset — the documented state of a
        // "Manually only" fleet, and of anything re-served inside the poll floor. Clamping the
        // negative remainder to zero turned a spent quota into maximal headroom and let it lead.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: -3600)
        ])])
        let candidate = overview.candidates.first
        #expect(candidate?.headroom == nil)
        #expect(candidate?.canLead == false)
        #expect(candidate?.weeklyResetsAt == nil)
        // ...but the figure is still shown, so the row does not go blank.
        #expect(candidate?.bindingWeekly?.utilization == 0.2)
        #expect(overview.leader == nil)
    }

    @Test
    func aWindowWhoseOwnResetElapsedNeverBorrowsALiveOne() {
        // Saying nothing and saying something that has since passed are different states. A
        // window that named a reset and reached it has demonstrably rolled over, so lending it a
        // sibling's live deadline would put a spent week's figures back into the ranking — and a
        // `.fresh` snapshot re-served inside the poll floor could lead on them.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.7, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.05, resetsIn: -3600, model: "Fable")
        ])])
        // Lent the live deadline, the scoped window's stale 5% would have looked like the freest
        // budget on the account and bound instead; only the live weekly-all is measured.
        #expect(overview.candidates.first?.bindingWeekly?.isWeeklyAll == true)
        #expect(isClose(overview.candidates.first?.headroom, 0.30 - 0.5))
    }

    @Test
    func aLiveSiblingResetStillStandsInForAWindowThatReportedNone() {
        // The fallback survives the elapsed-reset rule, so long as the stand-in is still ahead.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.2, model: "Fable")
        ])])
        #expect(overview.candidates.first?.canLead == true)
        #expect(overview.candidates.first?.weeklyResetsAt == now.addingTimeInterval(halfWeek))
    }

    // MARK: - No clock, no claim

    @Test
    func aWindowWithNoResetTimeCannotLead() throws {
        // Nothing said when the window turns over, so there is no pace to compare a budget
        // against — the row still shows, but it must not become the instruction.
        let overview = rank([account("a", limits: [limit(UsageLimit.kindWeeklyAll, 0.2)])])
        let candidate = try #require(overview.candidates.first)
        #expect(candidate.headroom == nil)
        // Not `onPace` — that asserts a rate nothing here measured.
        #expect(candidate.state == .paceUnknown)
        #expect(candidate.canLead == false)
        #expect(overview.leader == nil)
    }

    @Test
    func aWindowThatReportedNoResetIsNotMeasuredAgainstASiblingsClock() {
        // Weekly windows reset independently — this fleet reports two whose dates differ — so a
        // sibling's deadline is no evidence of another's. The scoped window here stays unmeasured
        // rather than being lent a clock it never had; only the live weekly-all binds.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.2, model: "Fable")
        ])])
        #expect(overview.candidates.first?.bindingWeekly?.isWeeklyAll == true)
        #expect(isClose(overview.candidates.first?.headroom, 0.40))
        #expect(overview.candidates.first?.canLead == true)
    }

    // MARK: - The server's `is_active` headline

    @Test
    func everyWindowCountsWhateverTheServerCallsActive() {
        // `is_active` reads like "this window is in force", and filtering on it is the obvious
        // idea — it was tried and reverted. Across 8,730 stored snapshots exactly one window per
        // account carries the flag, always the one with the highest utilization: it is the
        // server's headline pick, not a claim about the other two. Honouring it here would drop
        // an exhausted window straight past the gate.
        var exhausted = limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 3600)
        exhausted.isActive = false
        var headline = limit(UsageLimit.kindSession, 0.1, resetsIn: 900)
        headline.isActive = true
        let overview = rank([account("a", limits: [headline, exhausted])])
        #expect(overview.candidates.first?.state == .out)
        #expect(overview.candidates.first?.canLead == false)
    }

    @Test
    func anInactiveWeeklyWindowStillCarriesItsBudget() {
        // The mirror of the above: an account whose headline is its session still has a weekly
        // budget, and filtering on the flag left it with none to measure.
        var week = limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        week.isActive = false
        var session = limit(UsageLimit.kindSession, 0.3, resetsIn: 900)
        session.isActive = true
        let overview = rank([account("a", limits: [session, week])])
        #expect(overview.candidates.first?.bindingWeekly?.isWeeklyAll == true)
        #expect(isClose(overview.candidates.first?.headroom, 0.30))
        #expect(overview.candidates.first?.canLead == true)
    }

    // MARK: - Stickiness

    @Test
    func aNarrowChallengerDoesNotUnseatTheStandingLeader() {
        // headroom: held 0.30, challenger 0.34 — a 0.04 margin, under `stickyMargin`.
        let overview = rank(
            [weeklyAccount("challenger", 0.16), weeklyAccount("held", 0.2)],
            previousLeader: "held"
        )
        #expect(overview.leader?.id == "held")
        #expect(overview.candidates.map(\.id) == ["held", "challenger"])
    }

    @Test
    func aClearChallengerTakesTheLead() {
        // headroom: held 0.30, challenger 0.36 — past the margin.
        let overview = rank(
            [weeklyAccount("challenger", 0.14), weeklyAccount("held", 0.2)],
            previousLeader: "held"
        )
        #expect(overview.leader?.id == "challenger")
    }

    @Test
    func aGatedLeaderLosesThePlaceHoweverNarrowTheMargin() {
        let overview = rank(
            [
                weeklyAccount("challenger", 0.5),
                account("held", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 600)])
            ],
            previousLeader: "held"
        )
        #expect(overview.leader?.id == "challenger")
        #expect(overview.candidates.map(\.id) == ["challenger", "held"])
    }

    @Test
    func stickinessIsInertWhenTheLeaderIsAlreadyOnTop() {
        let plain = rank([weeklyAccount("a", 0.2), weeklyAccount("b", 0.5)])
        let sticky = rank([weeklyAccount("a", 0.2), weeklyAccount("b", 0.5)], previousLeader: "a")
        #expect(plain.candidates.map(\.id) == sticky.candidates.map(\.id))
    }

    @Test
    func anUnknownPreviousLeaderChangesNothing() {
        let overview = rank(
            [weeklyAccount("a", 0.2), weeklyAccount("b", 0.5)],
            previousLeader: "retired-account"
        )
        #expect(overview.candidates.map(\.id) == ["a", "b"])
    }

    // MARK: - Stability

    @Test
    func equalCandidatesKeepAStableOrder() {
        let forward = rank([weeklyAccount("b", 0.4), weeklyAccount("a", 0.4)])
        let reversed = rank([weeklyAccount("a", 0.4), weeklyAccount("b", 0.4)])
        #expect(forward.candidates.map(\.id) == ["a", "b"])
        #expect(reversed.candidates.map(\.id) == ["a", "b"])
    }
}

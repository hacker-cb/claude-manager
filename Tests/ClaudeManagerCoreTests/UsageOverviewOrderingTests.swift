import Foundation
import Testing
@testable import ClaudeManagerCore

/// What puts an account out of the running, which window is reported when several do at once,
/// and the proof that the resulting order is one `sorted(by:)` may actually be handed. Split from
/// `UsageOverviewTests`, which reached its length cap.
struct UsageOverviewOrderingTests {
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

    // MARK: - Gates

    @Test
    func anExhaustedWindowPutsTheAccountOut() throws {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 3600)
        ])])
        let candidate = try #require(overview.candidates.first)
        #expect(candidate.state == .out)
        #expect(candidate.canLead == false)
        #expect(overview.leader == nil)
    }

    @Test
    func nearlyFullWeeklyWindowIsGatedAtTheCriticalThreshold() {
        // The gate is `UsageLimit.criticalUtilization`, the same 0.90 that paints a bar red —
        // the board must never send anyone to a red bar.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, UsageLimit.criticalUtilization, resetsIn: halfWeek)
        ])])
        #expect(overview.candidates.first?.state == .nearlyOut)
        #expect(overview.candidates.first?.canLead == false)
    }

    @Test
    func aFullSessionWindowGatesButIsNamedApart() throws {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ])])
        let candidate = try #require(overview.candidates.first)
        #expect(candidate.state == .sessionNearlyFull)
        #expect(candidate.canLead == false)
        // The weekly window is still reported — it is what the account will have when the
        // session frees up in fifteen minutes.
        #expect(candidate.bindingWeekly?.isWeeklyAll == true)
        #expect(candidate.freesAt == now.addingTimeInterval(900))
    }

    @Test
    func sessionUsageBelowTheGateNeverEntersHeadroom() {
        // A busy-but-not-full session must not move the ranking: it refills within hours, and
        // charging it against the week would send someone to another profile every session.
        let withSession = rank([account("a", limits: [
            limit(UsageLimit.kindSession, 0.89, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ])])
        #expect(isClose(withSession.candidates.first?.headroom, 0.30))
        #expect(withSession.candidates.first?.state == .spend)
    }

    @Test
    func exhaustionOutranksNearlyOutWhenBothApply() {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: halfWeek)
        ])])
        #expect(overview.candidates.first?.state == .out)
        #expect(overview.candidates.first?.gatingLimit?.isWeeklyAll == true)
    }

    // MARK: - Ordering among accounts that are out

    @Test
    func gatedAccountsAreOrderedBySoonestReturn() {
        let overview = rank([
            account("late", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 7200)]),
            account("soon", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 600)])
        ])
        #expect(overview.candidates.map(\.id) == ["soon", "late"])
        #expect(overview.soonestReturn == now.addingTimeInterval(600))
    }

    @Test
    func soonestReturnIgnoresAResetThatHasAlreadyPassed() {
        // A retained snapshot can carry an elapsed reset; taking the plain minimum returned a
        // moment in the past and hid the real return the other account was about to offer.
        let overview = rank([
            account("stale-gate", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: -7200)]),
            account("live-gate", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 600)])
        ])
        #expect(overview.soonestReturn == now.addingTimeInterval(600))
    }

    @Test
    func aFleetWhoseGatesHaveAllElapsedOffersNoReturnTime() {
        let overview = rank([
            account("a", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: -7200)])
        ])
        #expect(overview.soonestReturn == nil)
    }

    @Test
    func anElapsedGateStopsGatingRatherThanPinningTheAccountAtOut() {
        // Once a window's own period has ended, its figures cannot hold an account down: the
        // week has certainly reset and nothing has re-read it. The account that is *known* to be
        // out stays out; the one whose evidence expired is merely unrateable, which is a better
        // place in the list, not a worse one.
        let overview = rank([
            account("elapsed", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: -7200)]),
            account("known", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 600)])
        ])
        #expect(overview.candidates.map(\.id) == ["elapsed", "known"])
        #expect(overview.candidates.first?.state == .paceUnknown)
        #expect(overview.candidates.first?.canLead == false)
        #expect(overview.candidates.last?.state == .out)
        #expect(overview.soonestReturn == now.addingTimeInterval(600))
    }

    @Test
    func twoScopedGatesTieOnTheirOwnIdentityNotOnPayloadOrder() {
        // Both windows share a kind, a reset and a percentage, and differ only by model — so a
        // tie broken on `rawKind` left the named blocker, and the model the reader sees, decided
        // by the order the server happened to list them in.
        let windows = [
            limit(UsageLimit.kindWeeklyScoped, 0.95, resetsIn: 3600, model: "Opus"),
            limit(UsageLimit.kindWeeklyScoped, 0.95, resetsIn: 3600, model: "Fable")
        ]
        let forward = rank([account("a", limits: windows)]).candidates.first
        let reversed = rank([account("a", limits: windows.reversed())]).candidates.first
        #expect(forward?.gatingLimit?.scopeModelName == "Fable")
        #expect(forward?.gatingLimit?.scopeModelName == reversed?.gatingLimit?.scopeModelName)
    }

    @Test
    func windowsWithEqualHeadroomBindDeterministically() {
        let windows = [
            limit(UsageLimit.kindWeeklyScoped, 0.5, resetsIn: halfWeek, model: "Opus"),
            limit(UsageLimit.kindWeeklyScoped, 0.5, resetsIn: halfWeek, model: "Fable")
        ]
        let forward = rank([account("a", limits: windows)]).candidates.first
        let reversed = rank([account("a", limits: windows.reversed())]).candidates.first
        #expect(forward?.bindingWeekly?.scopeModelName == "Fable")
        #expect(forward?.bindingWeekly?.scopeModelName == reversed?.bindingWeekly?.scopeModelName)
    }

    @Test
    func anExhaustedSessionIsStillOnlyASession() {
        // Asking about exhaustion before asking whether the session is the only gate read a 100%
        // session as `out` — below an account with 94% of its *week* gone — and twenty minutes
        // later the same profile was best again. That churn is what this state exists to prevent.
        let overview = rank([
            account("session-full", limits: [
                limit(UsageLimit.kindSession, 1.0, resetsIn: 900),
                limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
            ]),
            account("week-nearly-gone", limits: [
                limit(UsageLimit.kindWeeklyAll, 0.94, resetsIn: 3 * 24 * 3600)
            ])
        ])
        #expect(overview.candidates.first?.state == .sessionNearlyFull)
        #expect(overview.candidates.map(\.id) == ["session-full", "week-nearly-gone"])
    }

    @Test
    func aLiveGateIsNotHiddenBehindAnExpiredOne() {
        // The session is live and genuinely blocking; the week's 100% is from a period that
        // ended five hours ago. Letting the expired figure name the blocker printed "7d 100%"
        // with no countdown and left the real, dated wait unmentioned.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: -5 * 3600),
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900)
        ])])
        let candidate = overview.candidates.first
        #expect(candidate?.state == .sessionNearlyFull)
        #expect(candidate?.gatingLimit?.isSession == true)
        #expect(candidate?.freesAt == now.addingTimeInterval(900))
    }

    // MARK: - The ordering is a real ordering

    @Test
    func theOrderingIsAsymmetricAndTransitiveAcrossEveryShape() {
        // `sorted(by:)` requires a strict weak ordering; a comparator with a cycle in it has
        // undefined behaviour, not merely a surprising result. This asserts the property over
        // one candidate of every shape the ranking can produce, rather than trusting a reading.
        let fleet = [
            weeklyAccount("a-spend", 0.1),
            weeklyAccount("b-pace", 0.5),
            weeklyAccount("c-fast", 0.8),
            weeklyAccount("d-stale", 0.2, state: .offline),
            account("e-noclock", limits: [limit(UsageLimit.kindWeeklyAll, 0.2)]),
            account("f-session", limits: [
                limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
                limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
            ]),
            account("g-near-soon", limits: [limit(UsageLimit.kindWeeklyAll, 0.95, resetsIn: 3600)]),
            account("h-near-late", limits: [limit(UsageLimit.kindWeeklyAll, 0.95, resetsIn: 7200)]),
            account("i-near-noreset", limits: [limit(UsageLimit.kindWeeklyAll, 0.95)]),
            account("j-out", limits: [limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 600)]),
            account("k-signedout", limits: [], state: .noSource(.signedOut))
        ]
        let candidates = rank(fleet).candidates
        #expect(candidates.count == fleet.count)
        for left in candidates {
            #expect(!UsageOverview.precedes(left, left)) // irreflexive
            for right in candidates where left.id != right.id {
                let forward = UsageOverview.precedes(left, right)
                let backward = UsageOverview.precedes(right, left)
                #expect(!(forward && backward)) // asymmetric
                #expect(forward || backward) // total: no two distinct candidates are unordered
            }
        }
        for left in candidates {
            for middle in candidates where UsageOverview.precedes(left, middle) {
                for right in candidates where UsageOverview.precedes(middle, right) {
                    #expect(UsageOverview.precedes(left, right)) // transitive
                }
            }
        }
    }

    @Test
    func aGatedWindowThatReportedNoResetSortsLastAndBreaksNoCycle() {
        // The exact triple that used to cycle: two dated gates and one that never said when it
        // frees, with uuids chosen so the old uuid fallback disagreed with the dates.
        let fleet = [
            account("zzz", limits: [limit(UsageLimit.kindWeeklyAll, 0.95, resetsIn: 3600)]),
            account("mmm", limits: [limit(UsageLimit.kindWeeklyAll, 0.95)]),
            account("aaa", limits: [limit(UsageLimit.kindWeeklyAll, 0.95, resetsIn: 7200)])
        ]
        #expect(rank(fleet).candidates.map(\.id) == ["zzz", "aaa", "mmm"])
        // ...and the answer does not depend on the order the accounts arrived in.
        #expect(rank(fleet.reversed()).candidates.map(\.id) == ["zzz", "aaa", "mmm"])
    }

    // MARK: - Gates the server declares

    @Test
    func aWindowTheServerCallsCriticalGatesBelowNinetyPercent() {
        // The server escalates for things a percentage cannot express — a plan policy, an
        // account restriction, a window kind this build has no model for — and every bar in the
        // app already paints that as red. The ranking must not send work to a red bar.
        var flagged = limit(UsageLimit.kindWeeklyAll, 0.40, resetsIn: halfWeek)
        flagged.severity = .critical
        let overview = rank([account("a", limits: [flagged])])
        #expect(overview.candidates.first?.state == .nearlyOut)
        #expect(overview.leader == nil)
    }

    @Test
    func aServerSeverityBelowCriticalDoesNotGate() {
        var warned = limit(UsageLimit.kindWeeklyAll, 0.20, resetsIn: halfWeek)
        warned.severity = .warning
        #expect(rank([account("a", limits: [warned])]).candidates.first?.state == .spend)
    }

    // MARK: - Several gates at once

    @Test
    func theGateReportedIsTheOneThatBlocksLongest() {
        // A session freeing in fifteen minutes beside a week freeing in three days is not a
        // fifteen-minute wait: quoting the session there promises a return the week won't honour.
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 0.94, resetsIn: 3 * 24 * 3600)
        ])])
        let candidate = overview.candidates.first
        #expect(candidate?.state == .nearlyOut)
        #expect(candidate?.gatingLimit?.isWeeklyAll == true)
        #expect(candidate?.freesAt == now.addingTimeInterval(3 * 24 * 3600))
        #expect(overview.soonestReturn == now.addingTimeInterval(3 * 24 * 3600))
    }

    @Test
    func aSessionGateAloneStillReadsAsASessionGate() {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ])])
        #expect(overview.candidates.first?.state == .sessionNearlyFull)
        #expect(overview.candidates.first?.freesAt == now.addingTimeInterval(900))
    }

    @Test
    func exhaustionNamesTheStateWhileTheLongestBlockerNamesTheReturn() {
        let overview = rank([account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 900),
            limit(UsageLimit.kindSession, 0.95, resetsIn: 3600)
        ])])
        // Something is exhausted, so the account is out — but it is not usable again until the
        // session clears an hour from now either.
        #expect(overview.candidates.first?.state == .out)
        #expect(overview.candidates.first?.freesAt == now.addingTimeInterval(3600))
    }

    @Test
    func anEmptyFleetHasNoLeaderAndNoReturnTime() {
        let overview = rank([])
        #expect(overview.candidates.isEmpty)
        #expect(overview.leader == nil)
        #expect(overview.soonestReturn == nil)
    }
}

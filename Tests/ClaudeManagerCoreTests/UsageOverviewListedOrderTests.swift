import Foundation
import Testing
@testable import ClaudeManagerCore

/// The two orders `UsageOverview` carries: `candidates`, ranked, which is the answer, and
/// `listed`, the fleet as every surface shows it.
///
/// An extension in its own file: the suite body is at the `type_body_length` cap, and these
/// build their own values rather than reaching for the main file's private builders.
extension UsageOverviewOrderingTests {
    private var clock: Date {
        Date(timeIntervalSince1970: 1_000_000_000)
    }

    private var half: TimeInterval {
        LimitEvaluator.sevenDayWindow / 2
    }

    private func weekly(_ utilization: Double) -> UsageLimit {
        UsageLimit(
            rawKind: UsageLimit.kindWeeklyAll,
            utilization: utilization,
            resetsAt: clock.addingTimeInterval(half),
            isActive: true
        )
    }

    private func acc(_ uuid: String, _ limits: [UsageLimit], state: UsageState = .fresh) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid),
            snapshot: limits.isEmpty && state != .fresh
                ? nil
                : UsageSnapshot(limits: limits, capturedAt: clock),
            state: state,
            bindingIDs: [uuid]
        )
    }

    // MARK: - Two orders, one input

    @Test
    func listedKeepsTheOrderTheAccountsCameInWhileTheRankingSortsThem() {
        // The whole mechanism: one sorted sequence, the caller's. `listed` preserves it so the
        // table cannot drift from the sidebar, while `candidates` is free to answer "where now".
        let spent = acc("a", [weekly(0.98)])
        let free = acc("b", [weekly(0.05)])
        let overview = UsageOverview.rank(accounts: [spent, free], mode: .scopedModel, now: clock)
        #expect(overview.listed.map(\.id) == ["a", "b"])
        #expect(overview.candidates.first?.id == "b")
        #expect(overview.leader?.id == "b")
    }

    @Test
    func listedAndCandidatesHoldTheSameAccounts() {
        // Two orders of one set, never two sets: a row missing from the table would be an account
        // the ranking still reasons about and nobody can see.
        let accounts = [
            acc("a", [weekly(0.98)]),
            acc("b", [UsageLimit(
                rawKind: UsageLimit.kindSession,
                utilization: 1.0,
                resetsAt: clock.addingTimeInterval(3600),
                isActive: true
            )]),
            acc("c", [], state: .loginNeeded)
        ]
        let overview = UsageOverview.rank(accounts: accounts, mode: .scopedModel, now: clock)
        #expect(Set(overview.listed.map(\.id)) == Set(overview.candidates.map(\.id)))
        #expect(overview.listed.count == 3)
    }

    @Test
    func stickinessMovesTheAnswerAndLeavesTheTableAlone() {
        // Damping is about which account is recommended, not about where its row sits.
        let held = acc("a", [weekly(0.50)])
        let rival = acc("b", [weekly(0.48)])
        let overview = UsageOverview.rank(
            accounts: [held, rival], mode: .scopedModel, previousLeader: "a", now: clock
        )
        #expect(overview.leader?.id == "a")
        #expect(overview.listed.map(\.id) == ["a", "b"])
    }
}

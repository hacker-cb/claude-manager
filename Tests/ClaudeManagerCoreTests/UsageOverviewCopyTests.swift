import Foundation
import Testing
@testable import ClaudeManagerCore

/// What the board *says*. Two things are pinned here: that a mode is never named after a model
/// this build compiled in, and that a candidate needing a person keeps the vocabulary the rest
/// of the app already uses for that condition.
struct UsageOverviewCopyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private var halfWeek: TimeInterval {
        LimitEvaluator.sevenDayWindow / 2
    }

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
            identity: AccountIdentity(uuid: uuid),
            snapshot: limits.isEmpty && state != .fresh
                ? nil
                : UsageSnapshot(limits: limits, capturedAt: now),
            state: state,
            bindingIDs: [uuid]
        )
    }

    private func reason(_ account: AccountUsage, mode: WorkMode = .scopedModel) throws -> String {
        let overview = UsageOverview.rank(accounts: [account], mode: mode, now: now)
        return try UsageOverview.reason(for: #require(overview.candidates.first), now: now)
    }

    // MARK: - Naming the mode from data, never from a literal

    @Test
    func scopedModeIsNamedAfterTheModelTheServerReported() {
        let accounts = [account("a", limits: [
            limit(UsageLimit.kindWeeklyScoped, 0.2, resetsIn: halfWeek, model: "Fable")
        ])]
        #expect(UsageOverview.modeLabel(.scopedModel, accounts: accounts) == "Fable work")
        #expect(UsageOverview.modeLabel(.otherWork, accounts: accounts) == "Other work")
    }

    @Test
    func aRenamedModelRenamesTheModeWithNoBuildInBetween() {
        // The whole reason `WorkMode` has no `.fable` case: this label follows the payload.
        let accounts = [account("a", limits: [
            limit(UsageLimit.kindWeeklyScoped, 0.2, resetsIn: halfWeek, model: "Sonnet")
        ])]
        #expect(UsageOverview.modeLabel(.scopedModel, accounts: accounts) == "Sonnet work")
    }

    @Test
    func severalScopedModelsAreAllNamed() {
        let accounts = [
            account("a", limits: [
                limit(UsageLimit.kindWeeklyScoped, 0.2, resetsIn: halfWeek, model: "Opus")
            ]),
            account("b", limits: [
                limit(UsageLimit.kindWeeklyScoped, 0.3, resetsIn: halfWeek, model: "Fable")
            ])
        ]
        #expect(UsageOverview.scopedModelNames(in: accounts) == ["Fable", "Opus"])
        #expect(UsageOverview.modeLabel(.scopedModel, accounts: accounts) == "Fable / Opus work")
    }

    @Test
    func aModelNameIsListedOnceHoweverManyAccountsReportIt() {
        let accounts = (1 ... 3).map {
            account("a\($0)", limits: [
                limit(UsageLimit.kindWeeklyScoped, 0.2, resetsIn: halfWeek, model: "Fable")
            ])
        }
        #expect(UsageOverview.scopedModelNames(in: accounts) == ["Fable"])
    }

    @Test
    func withNoScopedWindowTheModesCannotDiffer() {
        // A plan reporting no per-model window makes the toggle a control that does nothing —
        // the surfaces gate on this rather than offering two identical answers.
        let accounts = [account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ])]
        #expect(UsageOverview.hasScopedWindows(in: accounts) == false)
        #expect(UsageOverview.modeLabel(.scopedModel, accounts: accounts) == "Per-model work")
    }

    // MARK: - The sentence

    @Test
    func spendingSaysWhatIsLostByNotSpending() throws {
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ]))
        #expect(text == "80% of 7d left · resets in 3d 12h — unused budget is gone at reset")
    }

    @Test
    func onPaceAndBurningFastReadAsRates() throws {
        let onPace = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.5, resetsIn: halfWeek)
        ]))
        #expect(onPace == "50% of 7d left · 3d 12h to go — on pace")
        let fast = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.8, resetsIn: halfWeek)
        ]))
        #expect(fast == "20% of 7d left · 3d 12h to go — burning faster than the week")
    }

    @Test
    func anExhaustedAccountSaysWhenItComesBack() throws {
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 3600)
        ]))
        #expect(text == "7d 100% · back in 1h 0m")
    }

    @Test
    func aFullSessionSaysWhenItFrees() throws {
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindSession, 0.95, resetsIn: 900),
            limit(UsageLimit.kindWeeklyAll, 0.2, resetsIn: halfWeek)
        ]))
        #expect(text == "5h 95% · frees in 15m")
    }

    @Test
    func aNearlyOutScopedWindowNamesItsModel() throws {
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 0.1, resetsIn: halfWeek),
            limit(UsageLimit.kindWeeklyScoped, 0.98, resetsIn: 7200, model: "Fable")
        ]))
        #expect(text == "7d·Fable 98% · frees in 2h 0m")
    }

    @Test
    func aBindingNeedingAPersonKeepsTheAppsExistingWording() throws {
        // Not a second vocabulary for one condition: the sidebar and the detail pane already
        // say this, and two phrasings would be two different remedies for the same thing.
        let signedOut = account("a", limits: [], state: .noSource(.signedOut))
        let text = try reason(signedOut)
        #expect(text == UsagePresentation.stateNote(signedOut, now: now))
        #expect(text == "signed out")
    }

    @Test
    func anAccountWithNothingReadSaysSo() throws {
        let bare = AccountUsage(
            identity: AccountIdentity(uuid: "bare"),
            snapshot: nil,
            state: .fresh,
            bindingIDs: ["bare"]
        )
        #expect(try reason(bare) == "no usage read yet")
    }

    @Test
    func anElapsedWindowStopsBeingAVerdictAtAll() throws {
        // Its percentage describes a week that is over, so it may no more raise a verdict than
        // lower one: the account is not called `out` on it, and the row falls back to the figure
        // with no countdown rather than a permanent "resetting…".
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: -3600)
        ]))
        #expect(text == "0% of 7d left")
    }

    @Test
    func theVerbFollowsTheWindowNamedNotTheRowsState() throws {
        // The state is the most severe thing happening; the figure is the window that blocks
        // longest, and those are not always the same window. "back in 1h" beside a 95% session
        // read as a claim about that session being spent.
        let text = try reason(account("a", limits: [
            limit(UsageLimit.kindWeeklyAll, 1.0, resetsIn: 900),
            limit(UsageLimit.kindSession, 0.95, resetsIn: 3600)
        ]))
        #expect(text == "5h 95% · frees in 1h 0m")
    }

    @Test
    func aWindowWithNoUsableResetPrintsItsFigureAndClaimsNoPace() throws {
        let text = try reason(account("a", limits: [limit(UsageLimit.kindWeeklyAll, 0.2)]))
        #expect(text == "80% of 7d left")
        // Worded for both causes: a reset never reported, and one reported that has passed.
        #expect(UsageOverview.stateLabel(.paceUnknown) == "Pace unknown")
    }

    // MARK: - State labels

    @Test
    func everyStateHasALabel() {
        for state in CandidateState.allCases {
            #expect(!UsageOverview.stateLabel(state).isEmpty)
        }
    }

    // MARK: - Compact durations

    @Test
    func compactDurationStepsThroughItsUnits() {
        #expect(UsageFormat.compactDuration(0) == "now")
        #expect(UsageFormat.compactDuration(-60) == "now")
        #expect(UsageFormat.compactDuration(30) == "<1m")
        #expect(UsageFormat.compactDuration(90) == "1m")
        #expect(UsageFormat.compactDuration(3600) == "1h 0m")
        #expect(UsageFormat.compactDuration(10320) == "2h 52m")
        #expect(UsageFormat.compactDuration(86400) == "1d 0h")
        #expect(UsageFormat.compactDuration(506_400) == "5d 20h")
    }
}

import Foundation
import Testing
@testable import ClaudeManagerCore

struct LimitEvaluatorTests {
    private let evaluator = LimitEvaluator()
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func weekly(_ util: Double, remaining: TimeInterval) -> UsageLimit {
        UsageLimit(
            rawKind: UsageLimit.kindWeeklyAll,
            utilization: util,
            resetsAt: now.addingTimeInterval(remaining),
            isActive: true
        )
    }

    private func session(_ util: Double, remaining: TimeInterval) -> UsageLimit {
        UsageLimit(
            rawKind: UsageLimit.kindSession,
            utilization: util,
            resetsAt: now.addingTimeInterval(remaining),
            isActive: true
        )
    }

    private func snapshot(_ limits: [UsageLimit]) -> UsageSnapshot {
        UsageSnapshot(limits: limits)
    }

    // MARK: - Absolute tiers

    @Test
    func absoluteCriticalAtNinetyFive() {
        // Late in the window (pace fine) but nearly exhausted → still critical.
        let w = evaluator.warnings(for: snapshot([weekly(0.96, remaining: 3600)]), now: now)
        #expect(w.count == 1)
        #expect(w.first?.severity == .critical)
        #expect(w.first?.threshold == 0.95)
    }

    @Test
    func absoluteWarningAtNinety() {
        let w = evaluator.warnings(for: snapshot([weekly(0.91, remaining: 3600)]), now: now)
        #expect(w.first?.severity == .warning)
        #expect(w.first?.threshold == 0.90)
    }

    @Test
    func onlyMostSevereTierFiresPerLimit() {
        // 0.96 crosses both the 0.90 and 0.95 absolute tiers — exactly one warning, critical.
        let w = evaluator.warnings(for: snapshot([weekly(0.96, remaining: 3600)]), now: now)
        #expect(w.count == 1)
    }

    // MARK: - Time-relative (steady-but-fast burn caught early)

    @Test
    func weeklyWarnsWhenBurningFastEarlyInWindow() {
        // util 0.78, most of the 7-day window still remaining (progress ~0.02) → fires at 0.75.
        let w = evaluator.warnings(
            for: snapshot([weekly(0.78, remaining: LimitEvaluator.sevenDayWindow * 0.9)]),
            now: now
        )
        #expect(w.first?.severity == .warning)
        #expect(w.first?.threshold == 0.75)
    }

    @Test
    func weeklyDoesNotWarnWhenPacedLateInWindow() {
        // Same 0.78 usage but late in the window (progress ~0.9 > 0.60) and below 0.90 absolute
        // → no warning: this is sustainable pace.
        let w = evaluator.warnings(
            for: snapshot([weekly(0.78, remaining: LimitEvaluator.sevenDayWindow * 0.1)]),
            now: now
        )
        #expect(w.isEmpty)
    }

    @Test
    func belowFloorNeverWarns() {
        let w = evaluator.warnings(
            for: snapshot([weekly(0.65, remaining: LimitEvaluator.sevenDayWindow * 0.99)]),
            now: now
        )
        #expect(w.isEmpty)
    }

    @Test
    func sessionWarnsAtNinetyEarly() {
        let w = evaluator.warnings(
            for: snapshot([session(0.91, remaining: LimitEvaluator.fiveHourWindow * 0.5)]),
            now: now
        )
        #expect(w.first?.limitLabel == "5h")
        #expect(w.first?.severity == .warning)
    }

    // MARK: - Gating

    @Test
    func inactiveLimitsAreIgnored() {
        var limit = weekly(0.99, remaining: 3600)
        limit.isActive = false
        #expect(evaluator.warnings(for: snapshot([limit]), now: now).isEmpty)
    }

    @Test
    func scopedAndAllLimitsGetDistinctKeys() {
        var scoped = UsageLimit(
            rawKind: UsageLimit.kindWeeklyScoped, utilization: 0.96,
            resetsAt: now.addingTimeInterval(3600), isActive: true, scopeModelName: "Fable"
        )
        scoped.group = "weekly"
        let w = evaluator.warnings(for: snapshot([weekly(0.96, remaining: 3600), scoped]), now: now)
        #expect(w.count == 2)
        #expect(Set(w.map(\.limitKey)) == ["weekly_all", "weekly_scoped:Fable"])
    }
}

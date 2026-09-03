import Foundation
import Testing
@testable import ClaudeManagerCore

/// The forecast the timeline draws. Every case here is a claim about the future rendered on
/// screen, which is what makes it worth pinning rather than eyeballing.
struct UsageTrendTests {
    private let start = Date(timeIntervalSince1970: 1_000_000_000)
    private static let hour: TimeInterval = 3600

    private func points(_ values: [(hours: Double, all: Double?)]) -> [UsageSeriesPoint] {
        values.map {
            UsageSeriesPoint(
                at: start.addingTimeInterval($0.hours * Self.hour),
                session: nil,
                weeklyAll: $0.all,
                weeklyScoped: nil
            )
        }
    }

    private func isClose(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    // MARK: - Rate

    @Test
    func theRateIsUtilizationPerSecondOverThePeriod() {
        // 0.10 → 0.30 across two hours.
        let rate = UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.1), (1, 0.2), (2, 0.3)]))
        #expect(isClose(rate, 0.2 / (2 * Self.hour)))
    }

    @Test
    func theRateIsMeasuredFromTheLastResetNotTheStart() {
        // The window turned over at hour 2. Measuring from hour 0 would read a fresh period as
        // carrying the previous one's spending.
        let series = points([(0, 0.8), (1, 0.9), (2, 0.02), (3, 0.06)])
        #expect(isClose(UsageTrend.rate(of: \.weeklyAll, in: series), 0.04 / Self.hour))
    }

    @Test
    func aFlatWindowHasARateOfZero() {
        #expect(UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.5), (1, 0.5)])) == 0)
    }

    @Test
    func aSeriesEndingOnADropHasNoRateYet() {
        // The drop *is* the period boundary, so the current period holds one sample and a rate
        // needs two. No projection is drawn until the next poll — which is right: nothing yet
        // says how fast the new window is being spent. (The earlier version of this test fed a
        // flat series and claimed to be covering a decrease, so it asserted nothing of the kind.)
        #expect(UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.9), (1, 0.02)])) == nil)
        #expect(UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.9), (1, 0.02), (2, 0.05)]))
            == 0.03 / Self.hour)
    }

    // MARK: - A boundary the caller knows

    @Test
    func aSuppliedPeriodStartBeatsTheDropHeuristic() {
        // A week spent idle resets 0% → 0% and leaves no drop to find; the heuristic then
        // averages across a boundary that is really there. The caller knows when the period
        // began — the reset is seven days before the next one — so it can say.
        let series = points([(0, 0), (1, 0), (2, 0), (3, 0.1)])
        // Inferred: no drop anywhere, so it averages over the whole three hours.
        #expect(isClose(UsageTrend.rate(of: \.weeklyAll, in: series), 0.1 / (3 * Self.hour)))
        // Told the period began at hour 2, it measures only the hour that belongs to it.
        #expect(isClose(
            UsageTrend.rate(
                of: \.weeklyAll, in: series, since: start.addingTimeInterval(2 * Self.hour)
            ),
            0.1 / Self.hour
        ))
    }

    @Test
    func aToldBoundaryStopsACorrectionReadingAsANewPeriod() {
        // A week climbing 0.10 → 0.50, then one poll reporting 0.49, then 0.50 again. Left to the
        // drop heuristic the measurement collapses to that last hour and the rate is an order of
        // magnitude too high — which is what the projection is drawn from.
        let series = points([(0, 0.1), (144, 0.5), (145, 0.49), (146, 0.5)])
        let told = UsageTrend.rate(of: \.weeklyAll, in: series, since: start)
        #expect(isClose(told, 0.4 / (146 * Self.hour)))
        let inferred = UsageTrend.rate(of: \.weeklyAll, in: series)
        #expect(isClose(inferred, 0.01 / Self.hour))
        // The told rate is the honest one, and far lower than what the heuristic reported.
        #expect((told ?? 0) < (inferred ?? 0))
    }

    @Test
    func aCorrectionAtTheEndLeavesNothingToMeasureRatherThanAFlatRate() {
        // Both readings of the period go *down*, so its lowest is the last one and there is no
        // span to measure over. Reporting zero instead would put a flat dashed line on the
        // timeline promising the account finishes the week exactly where it stands.
        #expect(UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.5), (1, 0.4)]), since: start) == nil)
    }

    @Test
    func oneLowReadingDoesNotCollapseTheSpan() {
        // The mirror of the case below, and the one a minimum-baseline reintroduced: a corrected
        // poll late in the week became the anchor, leaving an hour of span holding the whole
        // week's delta — a 60% account forecast to run out within the hour.
        let series = points([(0, 0.02), (130, 0.60), (131, 0.01), (132, 0.60)])
        #expect(isClose(
            UsageTrend.rate(of: \.weeklyAll, in: series, since: start), 0.58 / (132 * Self.hour)
        ))
    }

    @Test
    func aCorrectionAtTheTailKeepsTheSpanItWasMeasuredOver() {
        // The last reading is taken at its word — it is the freshest statement of the quantity —
        // but a correction of a percentage point must not shorten what it is measured against.
        let series = points([(0, 0.10), (10, 0.50), (11, 0.49)])
        #expect(isClose(
            UsageTrend.rate(of: \.weeklyAll, in: series, since: start), 0.39 / (11 * Self.hour)
        ))
    }

    @Test
    func oneHighReadingDoesNotPoisonTheWholePeriod() {
        // Taking the period's *first* sample as the baseline let a single spurious high reading
        // clamp every honest one after it to a zero rate — for the rest of the week.
        let series = points([(0, 0.85), (1, 0.10), (25, 0.34)])
        #expect(isClose(
            UsageTrend.rate(of: \.weeklyAll, in: series, since: start), 0.24 / (24 * Self.hour)
        ))
    }

    @Test
    func aSpikeEveryLaterReadingContradictsIsNotAnEndpoint() {
        // Taking the period's *highest* sample kept a figure the server had plainly corrected:
        // `0.80` between readings of `0.10` and `0.12` was measured as though it had been real,
        // drawing exhaustion hours out on a window with days left.
        let series = points([(0, 0.10), (1, 0.80), (2, 0.11), (3, 0.12)])
        #expect(isClose(
            UsageTrend.rate(of: \.weeklyAll, in: series, since: start), 0.02 / (3 * Self.hour)
        ))
    }

    @Test
    func aRunOfLeakedPreResetSamplesIsNotMeasuredInside() {
        // Dropping a single leading outlier was not the bound it looked like: two samples of the
        // previous period in a row left the whole rate measured inside last week, so a window
        // sitting at 15% was drawn running out by tomorrow.
        let series = points([(0, 0.50), (1, 0.55), (2, 0.10), (3, 0.15)])
        #expect(isClose(
            UsageTrend.rate(of: \.weeklyAll, in: series, since: start), 0.05 / Self.hour
        ))
    }

    @Test
    func aPeriodStartAfterEverySampleLeavesNothingToMeasure() {
        let series = points([(0, 0.2), (1, 0.4)])
        #expect(UsageTrend.rate(
            of: \.weeklyAll, in: series, since: start.addingTimeInterval(5 * Self.hour)
        ) == nil)
    }

    @Test
    func aSeriesWithNothingToMeasureHasNoRate() {
        #expect(UsageTrend.rate(of: \.weeklyAll, in: []) == nil)
        #expect(UsageTrend.rate(of: \.weeklyAll, in: points([(0, 0.4)])) == nil)
        // A window this series never reported.
        #expect(UsageTrend.rate(of: \.weeklyScoped, in: points([(0, 0.4), (1, 0.5)])) == nil)
    }

    @Test
    func gapsInOneWindowDoNotBreakTheOther() {
        let mixed = [
            UsageSeriesPoint(at: start, session: nil, weeklyAll: 0.1, weeklyScoped: nil),
            UsageSeriesPoint(
                at: start.addingTimeInterval(Self.hour),
                session: nil, weeklyAll: nil, weeklyScoped: 0.5
            ),
            UsageSeriesPoint(
                at: start.addingTimeInterval(2 * Self.hour),
                session: nil, weeklyAll: 0.3, weeklyScoped: nil
            )
        ]
        #expect(isClose(UsageTrend.rate(of: \.weeklyAll, in: mixed), 0.2 / (2 * Self.hour)))
        #expect(UsageTrend.rate(of: \.weeklyScoped, in: mixed) == nil)
    }

    // MARK: - Runs

    @Test
    func aMissingValueBreaksTheRun() {
        let series = points([(0, 0.1), (1, nil), (2, 0.3)])
        let runs = UsageTrend.runs(of: \.weeklyAll, in: series, maxGap: 3 * Self.hour)
        #expect(runs.count == 2)
        #expect(runs.map(\.count) == [1, 1])
    }

    @Test
    func aStretchWithNoSampleAtAllBreaksTheRun() {
        // The case splitting on `nil` alone could never catch: the store emits one row per
        // *populated* bucket and nothing for an empty one, so a Mac asleep over a weekend leaves
        // two adjacent points days apart — and the chart drew a confident climb between them.
        let series = points([(0, 0.1), (1, 0.2), (60, 0.9), (61, 0.95)])
        let runs = UsageTrend.runs(of: \.weeklyAll, in: series, maxGap: 3 * Self.hour)
        #expect(runs.count == 2)
        #expect(runs.map(\.count) == [2, 2])
    }

    @Test
    func aGapOfExactlyTheToleranceStaysOneRun() {
        // "Three polls of tolerance" means three polls are fine, not that the third starts a new
        // line — an off-by-one here breaks a lane on every skipped poll.
        let series = points([(0, 0.1), (3, 0.2)])
        #expect(UsageTrend.runs(of: \.weeklyAll, in: series, maxGap: 3 * Self.hour).count == 1)
    }

    @Test
    func runsFollowTheirOwnWindow() {
        // A hole in one window is not a hole in the other: the scoped line breaks where the
        // scoped value is missing, and the all-models line runs straight through.
        let series = [
            UsageSeriesPoint(at: start, session: nil, weeklyAll: 0.1, weeklyScoped: 0.4),
            UsageSeriesPoint(
                at: start.addingTimeInterval(Self.hour),
                session: nil, weeklyAll: 0.2, weeklyScoped: nil
            ),
            UsageSeriesPoint(
                at: start.addingTimeInterval(2 * Self.hour),
                session: nil, weeklyAll: 0.3, weeklyScoped: 0.6
            )
        ]
        #expect(UsageTrend.runs(of: \.weeklyAll, in: series, maxGap: 3 * Self.hour).count == 1)
        #expect(UsageTrend.runs(of: \.weeklyScoped, in: series, maxGap: 3 * Self.hour).count == 2)
    }

    @Test
    func anEmptySeriesHasNoRuns() {
        #expect(UsageTrend.runs(of: \.weeklyAll, in: [], maxGap: 3 * Self.hour).isEmpty)
        #expect(UsageTrend.runs(
            of: \.weeklyScoped, in: points([(0, 0.1), (1, 0.2)]), maxGap: 3 * Self.hour
        ).isEmpty)
    }

    // MARK: - Projection

    @Test
    func theProjectionExtendsTheRate() {
        let series = points([(0, 0.1), (2, 0.3)])
        let target = start.addingTimeInterval(4 * Self.hour)
        #expect(isClose(UsageTrend.projected(of: \.weeklyAll, in: series, at: target), 0.5))
    }

    @Test
    func theProjectionIsClampedToTheAxis() {
        // A line drawn past the top of its own axis is not a forecast.
        let series = points([(0, 0.5), (1, 0.9)])
        let target = start.addingTimeInterval(10 * Self.hour)
        #expect(UsageTrend.projected(of: \.weeklyAll, in: series, at: target) == 1)
    }

    @Test
    func nothingIsProjectedBackwards() {
        let series = points([(1, 0.2), (2, 0.4)])
        #expect(UsageTrend.projected(of: \.weeklyAll, in: series, at: start) == nil)
    }

    // MARK: - Forecast

    @Test
    func aCrossingAlreadyBehindTheClockIsReportedAtTheClock() throws {
        // Under "Manually only" the last reading can be hours old on an account that is still
        // perfectly `.fresh`. Read an hour ago at 96% and climbing, the crossing lands *before*
        // now — and the whole "projected" segment was drawn to the left of the `now` mark, with
        // the moment it hits 100% sitting in the past.
        let series = points([(0, 0.90), (1, 0.96)])
        let now = start.addingTimeInterval(3 * Self.hour)
        let forecast = try #require(UsageTrend.forecast(
            of: \.weeklyAll,
            in: series,
            until: start.addingTimeInterval(72 * Self.hour),
            since: start,
            now: now
        ))
        #expect(forecast.value == 1)
        #expect(forecast.at == now)
    }

    @Test
    func aWindowStillClimbingIsForecastToItsReset() {
        let series = points([(0, 0.10), (10, 0.20)])
        let resetsAt = start.addingTimeInterval(30 * Self.hour)
        let forecast = UsageTrend.forecast(
            of: \.weeklyAll, in: series, until: resetsAt, since: start, now: start
        )
        #expect(forecast?.at == resetsAt)
        #expect(isClose(forecast?.value, 0.40))
    }

    @Test
    func nothingIsForecastPastAResetThatHasPassed() {
        let series = points([(0, 0.10), (10, 0.20)])
        #expect(UsageTrend.forecast(
            of: \.weeklyAll,
            in: series,
            until: start.addingTimeInterval(Self.hour),
            since: start,
            now: start.addingTimeInterval(2 * Self.hour)
        ) == nil)
    }

    // MARK: - Running out

    @Test
    func exhaustionIsWhereTheRateMeetsTheCeiling() {
        // 0.5 → 0.6 in an hour is 0.1/h, so the remaining 0.4 takes four more hours.
        let series = points([(0, 0.5), (1, 0.6)])
        let hit = UsageTrend.exhausts(
            of: \.weeklyAll, in: series, before: start.addingTimeInterval(24 * Self.hour)
        )
        #expect(hit == start.addingTimeInterval(5 * Self.hour))
    }

    @Test
    func aWindowThatDoesNotRunOutInRangeReportsNothing() {
        let series = points([(0, 0.5), (1, 0.51)])
        #expect(UsageTrend.exhausts(
            of: \.weeklyAll, in: series, before: start.addingTimeInterval(2 * Self.hour)
        ) == nil)
    }

    @Test
    func aFlatOrFullWindowNeverReportsExhaustion() {
        let far = start.addingTimeInterval(365 * 24 * Self.hour)
        #expect(UsageTrend.exhausts(of: \.weeklyAll, in: points([(0, 0.5), (1, 0.5)]), before: far) == nil)
        #expect(UsageTrend.exhausts(of: \.weeklyAll, in: points([(0, 0.9), (1, 1.0)]), before: far) == nil)
    }
}

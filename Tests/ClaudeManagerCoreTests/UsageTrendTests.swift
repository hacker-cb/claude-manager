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
    func aDecreaseWithinAPeriodNeverProducesANegativeRate() {
        // Only a reset lowers a utilization; a server correction must not draw a quota refilling.
        let series = points([(0, 0.5), (1, 0.5)])
        #expect(UsageTrend.rate(of: \.weeklyAll, in: series) == 0)
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

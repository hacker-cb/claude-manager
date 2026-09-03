import Foundation

/// Where a window is heading, read off the thinned history a timeline already has.
///
/// Pure and keyed on a `UsageSeriesPoint` field, so the same two functions serve every window and
/// `swift test` can assert them — the projection is a claim about the future drawn on screen, and
/// a claim drawn on screen is exactly the kind that earns a test.
public enum UsageTrend {
    /// How fast the window has been spent, as utilization per second. Nil when the series says
    /// nothing usable.
    ///
    /// **Measured from the last reset, not from the start of the series.** A window that turned
    /// over inside the range spent its whole previous period too, and averaging across that
    /// boundary describes a rate the account is not on — it would read a fresh week as though it
    /// were carrying last week's spending.
    ///
    /// Never negative: a decrease within one period is the server correcting a figure, not the
    /// account un-spending anything, and a downward projection would draw a quota refilling.
    public static func rate(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint]
    ) -> Double? {
        let usable = points.filter { $0[keyPath: window] != nil }
        guard let last = usable.last, let latest = last[keyPath: window] else { return nil }
        let start = usable[startIndex(of: window, in: usable)...].first
        guard let start, let first = start[keyPath: window] else { return nil }
        let seconds = last.at.timeIntervalSince(start.at)
        guard seconds > 0 else { return nil }
        return max(0, (latest - first) / seconds)
    }

    /// Where the window lands at `target` if it keeps that rate — clamped to 0…1, because a
    /// utilization is a fraction and a line drawn past the top of its own axis is not a forecast.
    /// Nil when there is no rate to project, or when `target` is behind the last reading.
    public static func projected(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        at target: Date
    ) -> Double? {
        let usable = points.filter { $0[keyPath: window] != nil }
        guard let last = usable.last, let latest = last[keyPath: window],
              let rate = rate(of: window, in: points)
        else { return nil }
        let seconds = target.timeIntervalSince(last.at)
        guard seconds >= 0 else { return nil }
        return (latest + rate * seconds).clamped(to: 0 ... 1)
    }

    /// When the window would reach 1.0 at its current rate, or nil if it does not before `limit`.
    /// What the timeline draws its "runs out first" mark on.
    public static func exhausts(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        before limit: Date
    ) -> Date? {
        let usable = points.filter { $0[keyPath: window] != nil }
        guard let last = usable.last, let latest = last[keyPath: window],
              let rate = rate(of: window, in: points), rate > 0, latest < 1
        else { return nil }
        let hit = last.at.addingTimeInterval((1 - latest) / rate)
        return hit < limit ? hit : nil
    }

    /// Index of the first point of the current period: just after the last drop, or 0.
    ///
    /// A "drop" is any decrease — the reset is the only thing that lowers a utilization, and a
    /// threshold here would have to guess how small a reset can be.
    private static func startIndex(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint]
    ) -> Int {
        var start = 0
        for index in 1 ..< max(1, points.count) {
            guard let previous = points[index - 1][keyPath: window],
                  let current = points[index][keyPath: window]
            else { continue }
            if current < previous { start = index }
        }
        return start
    }
}

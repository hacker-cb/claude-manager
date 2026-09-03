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
    /// **Measured from the current period, not from the start of the series.** A window that
    /// turned over inside the range spent its whole previous period too, and averaging across
    /// that boundary describes a rate the account is not on — it would read a fresh week as
    /// though it were carrying last week's spending.
    ///
    /// `periodStart` is where that period is *known* to begin, and a caller that knows it should
    /// say so. Inferring the boundary from a drop in utilization is the fallback, and it is only
    /// a heuristic: a week spent idle resets from 0% to 0% and leaves no drop to find, and the
    /// thinning can put the last pre-reset sample in a bucket whose representative is already the
    /// post-reset one. Both cases average across a boundary that is there.
    ///
    /// Never negative, and by construction rather than by clamping: the baseline is the period's
    /// lowest reading, so a decrease within it — the server correcting a figure, never the account
    /// un-spending anything — cannot pull the rate below zero or draw a quota refilling.
    public static func rate(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        since periodStart: Date? = nil
    ) -> Double? {
        let usable = points.filter { point in
            guard point[keyPath: window] != nil else { return false }
            guard let periodStart else { return true }
            return point.at >= periodStart
        }
        guard usable.last?[keyPath: window] != nil else { return nil }
        // A **told** boundary is the boundary: running the drop heuristic inside it as well read
        // every server correction as a fresh period, collapsing a week of history to the hour
        // after one poll reported 0.49 instead of 0.50. The heuristic is the fallback for when
        // nobody said, and only then.
        let period = periodStart == nil
            ? Array(usable[startIndex(of: window, in: usable)...])
            : usable
        // **Peak to base, and neither is simply an end of the series.** A utilization only grows
        // within its period, so every dip in one is the server correcting a figure — and a rate
        // read off the raw endpoints is at the mercy of whichever end the correction lands on.
        // Both mistakes were made here in turn: anchoring on the first sample let one spuriously
        // *high* reading clamp the whole week to a flat zero, and anchoring on the period's
        // lowest let one spuriously *low* one collapse the span to an hour while keeping the
        // week's whole delta — a 60% account was then forecast to run out in forty minutes.
        //
        // So: drop a leading sample that stands above everything after it — it did not belong to
        // this period, whether it leaked past a boundary shifted by DST or clock skew or was
        // simply corrected away. Then measure from what is left, first sample to the **last**
        // sample reaching its highest value, so a correction at the tail cannot lower the
        // endpoint and the span stays as long as the evidence allows.
        func value(_ point: UsageSeriesPoint) -> Double? {
            point[keyPath: window]
        }
        let measured = withoutLeadingOutlier(period, of: window)
        guard let base = measured.first, let first = value(base),
              let top = measured.compactMap(value).max(),
              let peak = measured.last(where: { value($0) == top })
        else { return nil }
        let seconds = peak.at.timeIntervalSince(base.at)
        // Zero span is a period whose peak *is* its baseline — one reading is not a rate.
        guard seconds > 0 else { return nil }
        // Non-negative by construction: the peak is never below the baseline.
        return (top - first) / seconds
    }

    /// The period without a leading sample that stands above everything after it.
    ///
    /// Such a sample is not a baseline: it belongs to the period before this one — leaked past a
    /// boundary shifted by DST or clock skew — or is a figure the server has since corrected down.
    /// Anchoring on it clamped a whole week's rate to zero.
    private static func withoutLeadingOutlier(
        _ period: [UsageSeriesPoint],
        of window: KeyPath<UsageSeriesPoint, Double?>
    ) -> [UsageSeriesPoint] {
        let rest = period.dropFirst()
        guard let opening = period.first?[keyPath: window],
              let restPeak = rest.compactMap({ $0[keyPath: window] }).max(),
              opening > restPeak
        else { return period }
        return Array(rest)
    }

    /// Where the window lands at `target` if it keeps that rate — clamped to 0…1, because a
    /// utilization is a fraction and a line drawn past the top of its own axis is not a forecast.
    /// Nil when there is no rate to project, or when `target` is behind the last reading.
    public static func projected(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        at target: Date,
        since periodStart: Date? = nil
    ) -> Double? {
        let usable = points.filter { $0[keyPath: window] != nil }
        guard let last = usable.last, let latest = last[keyPath: window],
              let rate = rate(of: window, in: points, since: periodStart)
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
        before limit: Date,
        since periodStart: Date? = nil
    ) -> Date? {
        let usable = points.filter { $0[keyPath: window] != nil }
        guard let last = usable.last, let latest = last[keyPath: window],
              let rate = rate(of: window, in: points, since: periodStart), rate > 0, latest < 1
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

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
    /// Never negative, and by construction rather than by clamping: the baseline is never above
    /// the endpoint, so a decrease within the period — the server correcting a figure, never the
    /// account un-spending anything — cannot pull the rate below zero or draw a quota refilling.
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
        guard let end = usable.last, let latest = end[keyPath: window] else { return nil }
        // A **told** boundary is the boundary: running the drop heuristic inside it as well read
        // every server correction as a fresh period, collapsing a week of history to the hour
        // after one poll reported 0.49 instead of 0.50. The heuristic is the fallback for when
        // nobody said, and only then.
        let period = periodStart == nil
            ? Array(usable[startIndex(of: window, in: usable)...])
            : usable
        // **The last reading is the endpoint, and the baseline is the first reading not above
        // it.** Three attempts were made at this before the rule was right, and each of the first
        // two was undone by the *other* engine's counter-example.
        //
        // What makes it hard: a utilization only grows within its period, so every dip in one is
        // a figure the server has corrected — but from two samples alone there is no telling
        // whether the earlier one was over-reported or the later one under-reported. Anchoring
        // on the series' first sample let one spurious *high* reading clamp a whole week to a
        // flat zero. Anchoring on the period's *lowest* let one spurious low reading collapse the
        // span to an hour while keeping the week's whole delta, forecasting a 60% account to run
        // out in forty minutes. Anchoring on the period's *highest* kept an interior spike that
        // every later reading contradicts — `0.10 → 0.80 → 0.11 → 0.12` measured as if 0.80 had
        // been real — and, since only a single leading sample was dropped, two leaked pre-reset
        // samples in a row (`0.50, 0.55, 0.10, 0.15`) were measured entirely inside last week.
        //
        // The last reading escapes all of it, because it is the freshest statement of the very
        // quantity being measured — nothing later contradicts it, and it is where the drawn line
        // starts in any case. Everything above it is then something later evidence disagrees
        // with: a corrected spike, or a sample that belongs to a period this one already
        // replaced. Skipping past all of them leaves the longest run of readings consistent with
        // where the window actually stands.
        guard let base = period.first(where: { point in
            guard let value = point[keyPath: window] else { return false }
            return value <= latest
        }), let first = base[keyPath: window] else { return nil }
        let seconds = end.at.timeIntervalSince(base.at)
        // Zero span is a period whose baseline *is* its last reading — one point is not a rate,
        // and neither is a series every earlier sample of which sits above where it ended.
        guard seconds > 0 else { return nil }
        return (latest - first) / seconds
    }

    /// The series split into the runs a line may actually be drawn through.
    ///
    /// Two things break a run, and only one of them was obvious. A `nil` value is a window the
    /// server did not report for a sample it did report — plainly a gap. The other is a stretch
    /// with **no sample at all**: `UsageHistoryStore.series` emits one row per *populated* bucket
    /// and nothing for an empty one, so a Mac asleep over a weekend, an app quit, or tracking
    /// switched off for a day leaves two adjacent points days apart with nothing between them.
    /// Splitting on `nil` alone therefore missed exactly the case it was written for, and a chart
    /// drew a confident climb — shaded fill and all — across hours nobody observed.
    ///
    /// `maxGap` is what counts as "no sample at all" rather than a missed poll; a caller that
    /// knows its own cadence should say so in terms of it.
    public static func runs(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        maxGap: TimeInterval
    ) -> [[UsageSeriesPoint]] {
        var out: [[UsageSeriesPoint]] = []
        var current: [UsageSeriesPoint] = []
        func close() {
            if !current.isEmpty { out.append(current) }
            current = []
        }
        for point in points {
            guard point[keyPath: window] != nil else {
                close()
                continue
            }
            // `maxGap` itself is still a run: a caller expressing a tolerance of "three polls"
            // means three polls are fine, not that the third one starts a new line.
            if let last = current.last, point.at.timeIntervalSince(last.at) > maxGap {
                close()
            }
            current.append(point)
        }
        close()
        return out
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

    /// Where the dashed continuation ends: the moment the window runs out, or the level it
    /// reaches by its reset — whichever comes first. Nil when there is nothing to forecast.
    ///
    /// The whole decision, rather than the two halves of it, because the *drawing* rule turned
    /// out to be part of the arithmetic. `exhausts` answers from the last reading, and under
    /// "Manually only" that reading can be hours old while the account is still perfectly
    /// `.fresh` — a window read an hour ago at 96% and climbing lands its crossing *before* now,
    /// so the entire "projected" segment was drawn to the left of the `now` rule with the moment
    /// it hits 100% sitting in the past. A crossing already behind the clock is reported at the
    /// clock: by this reckoning the window is out, and "out now" is the honest way to draw that.
    public static func forecast(
        of window: KeyPath<UsageSeriesPoint, Double?>,
        in points: [UsageSeriesPoint],
        until resetsAt: Date,
        since periodStart: Date? = nil,
        staleAfter: TimeInterval,
        now: Date
    ) -> (at: Date, value: Double)? {
        // A reset already behind us is not a horizon: the period this would forecast is over.
        guard resetsAt > now else { return nil }
        // And a reading too old to extend. `.fresh` is not an age bound — a snapshot is carried
        // forward untouched, and under "Manually only" nothing polls, so a refresh on Monday
        // leaves a perfectly `.fresh` account whose last reading is three days behind by
        // Thursday. Forecasting from it drew a confident dashed line across three days nobody
        // observed — through a hole the *solid* line, held to this same tolerance, refuses to
        // bridge. Whatever a caller will not draw a line across, it will not forecast from.
        guard let last = points.last(where: { $0[keyPath: window] != nil }),
              now.timeIntervalSince(last.at) <= staleAfter
        else { return nil }
        if let runsOut = exhausts(of: window, in: points, before: resetsAt, since: periodStart) {
            return (max(runsOut, now), 1)
        }
        guard let ahead = projected(of: window, in: points, at: resetsAt, since: periodStart)
        else { return nil }
        return (resetsAt, ahead)
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

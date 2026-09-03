import Charts
import ClaudeManagerCore
import SwiftUI

/// Every account's weekly windows on one axis: a week behind, a week ahead, "now" down the
/// middle.
///
/// The cards say where to work; this says why, and for how long. A percentage on its own cannot
/// distinguish an account that has been climbing steadily all week from one that spent everything
/// yesterday and has since stopped — and those want opposite decisions.
struct LimitsTimeline: View {
    @EnvironmentObject private var model: AppModel
    let now: Date

    private var range: ClosedRange<Date> {
        now.addingTimeInterval(-AppModel.limitsHistoryWindow) ...
            now.addingTimeInterval(AppModel.limitsHistoryWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("This week").font(.headline)
                Spacer()
                legend
            }
            let ranked = model.limitsOverview(mode: model.limitsMode, now: now).candidates
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, candidate in
                LimitsTimelineLane(
                    candidate: candidate,
                    points: model.limitsSeries[candidate.id] ?? [],
                    range: range,
                    now: now,
                    showsAxis: index == ranked.count - 1
                )
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key(color: .accentColor, dash: nil, text: "All models")
            // Only where such a window exists. On a plan reporting none the purple series is
            // never drawn, so the key named a line nobody could find — the same condition the
            // header's mode picker is already hidden for, two views apart.
            if model.limitsHasScopedWindows {
                key(color: .purple, dash: [4, 3], text: "Per-model")
            }
            key(color: .accentColor.opacity(0.5), dash: [2, 3], text: "projected")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// Drawn with the same colour and the same dash pattern as the mark it stands for. The
    /// earlier version dimmed a solid swatch instead of dashing it, so the two dashed series were
    /// indistinguishable from the solid one — a legend that cannot be told apart is not one.
    private func key(color: Color, dash: [CGFloat]?, text: String) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash ?? []))
            .frame(width: 16, height: 2)
            Text(text)
        }
    }
}

/// A deadline drawn on a lane, and what it belongs to.
private struct ResetMark: Identifiable {
    var id: String {
        label
    }

    let at: Date
    let label: String
}

/// One account's lane.
struct LimitsTimelineLane: View {
    @EnvironmentObject private var model: AppModel
    let candidate: UsageCandidate
    let points: [UsageSeriesPoint]
    let range: ClosedRange<Date>
    let now: Date
    let showsAxis: Bool

    /// A point on a drawn line. Charts wants one identifiable row per mark, and the optionals in
    /// `UsageSeriesPoint` are gaps rather than zeroes — dropping them here is what keeps a window
    /// nobody reported from being drawn as a quota spent to nothing.
    ///
    /// Identified by its own timestamp, not a fresh `UUID`: these are rebuilt several times per
    /// `body` and again on every minute tick, and a new identity each time makes Charts treat an
    /// unchanged series as an entirely new set of marks.
    private struct Plot: Identifiable {
        var id: Date {
            at
        }

        let at: Date
        let value: Double
    }

    /// How long a hole in the history has to be before it stops being a missed poll and starts
    /// being a stretch nothing is known about.
    ///
    /// Three hours, from the thinning step rather than from the poll interval, and deliberately
    /// so. The slowest cadence the settings offer is hourly, which puts kept samples an hour
    /// apart; the tolerance is inclusive, so one missed poll (2h) and two (3h) both stay one run
    /// and it takes three to break a line. Deriving it from `usagePollIntervalMinutes` was
    /// considered and lands on the same three hours at every setting the picker has — including
    /// "Manually only", which has no cadence to derive from.
    ///
    /// It is also what `forecast` is given for `staleAfter`, which couples the two on purpose:
    /// a hole the chart will not draw a line across is not one it should forecast from either.
    private var maxGap: TimeInterval {
        3 * AppModel.limitsHistoryStep
    }

    /// The drawn line, split at every gap — which `UsageTrend.runs` decides, under tests, because
    /// what counts as a gap turned out to be a rule rather than a `nil` check.
    private func segments(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [[Plot]] {
        UsageTrend.runs(of: window, in: points, maxGap: maxGap).map { run in
            run.compactMap { point in
                point[keyPath: window].map { Plot(at: point.at, value: $0) }
            }
        }
    }

    private func history(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [Plot] {
        segments(window).flatMap(\.self)
    }

    /// When *this* window turns over — not the candidate's `weeklyResetsAt`, which is only the
    /// deadline of whichever window the current mode found tightest. These windows reset
    /// independently (this fleet reports two whose dates differ), and in `.otherWork` the scoped
    /// one is not even counted, so using that date for both lines extrapolated one of them to a
    /// deadline its own quota does not reset on.
    private func reset(for window: KeyPath<UsageSeriesPoint, Double?>) -> Date? {
        guard let snapshot = candidate.account.snapshot else { return nil }
        if window == \.weeklyAll { return snapshot.weeklyAll?.resetsAt }
        // The series carries the highest scoped window per sample, so its reset is that one's.
        return snapshot.weeklyScoped.max { $0.utilization < $1.utilization }?.resetsAt
    }

    /// The dashed continuation: from the last reading to that window's own reset, at the rate it
    /// has been spent since it last turned over — measured from the period boundary the reset
    /// itself gives, rather than from a drop `UsageTrend` might not be able to see.
    ///
    /// Where it ends is `UsageTrend.forecast`'s call, not this view's: it **ends where the window
    /// would run out**, when that comes first. Drawn only to the reset, the endpoint is clamped
    /// to 1, so a quota heading for exhaustion on Friday was drawn reaching 100% on Sunday — the
    /// line said the right thing about the level and the wrong thing about the date, which is the
    /// half a timeline is read for.
    private func projection(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [Plot] {
        guard projectable(window), let resetsAt = reset(for: window),
              let last = history(window).last,
              let end = UsageTrend.forecast(
                  of: window,
                  in: points,
                  until: resetsAt,
                  since: resetsAt.addingTimeInterval(-LimitEvaluator.sevenDayWindow),
                  staleAfter: maxGap,
                  now: now
              )
        else { return [] }
        return [Plot(at: last.at, value: last.value), Plot(at: end.at, value: end.value)]
    }

    /// Whether a forecast for this window would mean anything.
    ///
    /// `UsageSeriesPoint.weeklyScoped` is the highest scoped window **per sample**, so with more
    /// than one per-model quota the plotted line can change which model it represents partway
    /// through — and every such switch looks like a drop. Extrapolating that to one model's reset
    /// would be a forecast about a series no single quota followed, so none is drawn. The server
    /// sends one scoped window today, where this is exact.
    private func projectable(_ window: KeyPath<UsageSeriesPoint, Double?>) -> Bool {
        // Only from figures that are still moving. A stale, offline, rate-limited or signed-out
        // account keeps its snapshot and its history, and an unqualified dashed line drawn from
        // those extends days-old readings through hours nobody observed — presented exactly like
        // a live forecast. It is the same rule the ranking applies to whether such an account may
        // lead at all. It is only half the guard, though: `.fresh` bounds nothing about *age*,
        // which is what `forecast`'s `staleAfter` is handed `maxGap` for.
        guard candidate.isCurrent else { return false }
        guard window == \.weeklyScoped else { return true }
        return (candidate.account.snapshot?.weeklyScoped.count ?? 0) == 1
    }

    /// The reset lines to draw, and what each belongs to.
    ///
    /// One unlabelled rule was right only while the two weekly windows turned over together.
    /// These reset independently — this fleet reports two whose dates differ — so in scoped mode
    /// the binding series had no mark at its own deadline while the only mark on the lane pointed
    /// at the other one's, contradicting both the projection and the resets column beside it.
    /// Drawn per *drawn* series, and named only where naming them apart is the point.
    ///
    /// Only a reset still ahead: one that has passed is not a countdown, and the ranking has
    /// already stopped reasoning from it.
    private var resetMarks: [ResetMark] {
        var found: [ResetMark] = []
        for (window, name) in [
            (\UsageSeriesPoint.weeklyAll, "all"),
            (\UsageSeriesPoint.weeklyScoped, "per-model")
        ] {
            guard !segments(window).isEmpty, let at = reset(for: window),
                  at > now, range.contains(at) else { continue }
            found.append(ResetMark(at: at, label: "resets · \(name)"))
        }
        // Named apart only where naming them apart is the point. Two windows turning over on the
        // same date are one deadline, and two labels for it is noise on a 62pt lane.
        guard found.count > 1, Set(found.map(\.at)).count > 1 else {
            return found.first.map { [ResetMark(at: $0.at, label: "resets")] } ?? []
        }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            chart
                .frame(height: 62)
                .chartXScale(domain: range)
                .chartYScale(domain: 0 ... 1)
                .chartYAxis {
                    // `Double` marks and a `Double` percent style. A `Decimal` format style casts
                    // the axis value to its own `FormatInput` at render, and against these values
                    // that cast fails silently — leaving grid lines with no scale at all on a
                    // chart whose entire subject is a percentage.
                    AxisMarks(values: [0.0, 1.0]) {
                        AxisGridLine()
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent())
                    }
                }
                .chartXAxis {
                    if showsAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) {
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 2)) { AxisGridLine() }
                    }
                }
                .accessibilityLabel(accessibilityText)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.limitsAccountName(candidate.account))
                .font(.caption).bold()
                .lineLimit(1)
            Text(UsageOverview.stateLabel(for: candidate, now: now))
                .font(.caption2)
                .foregroundStyle(candidate.canLead ? Color.accentColor : .secondary)
            Spacer(minLength: 6)
            Text(UsageOverview.reason(for: candidate, now: now))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(segments(\.weeklyAll).enumerated()), id: \.offset) { index, run in
                // The fill needs the per-run series as much as the line does: without one Charts
                // folds every run into a single area and shades straight across the gap, so a
                // correctly-broken line sat on top of a fill asserting usage through it.
                ForEach(run) { plot in
                    AreaMark(
                        x: .value("When", plot.at),
                        y: .value("Used", plot.value),
                        series: .value("All fill", "fill-\(index)")
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                }
                // A series per run, so Charts draws each as its own line instead of bridging the
                // gap between them.
                ForEach(run) { plot in
                    LineMark(
                        x: .value("When", plot.at),
                        y: .value("Used", plot.value),
                        series: .value("All", "all-\(index)")
                    )
                    .foregroundStyle(Color.accentColor)
                }
                // A run of one has no length, so a line draws nothing at all for it. Under
                // "Manually only" nothing polls, and every refresh days apart is its own run —
                // the whole lane would have come up blank with the history sitting right there.
                if run.count == 1, let only = run.first {
                    PointMark(
                        x: .value("When", only.at),
                        y: .value("Used", only.value)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(18)
                }
            }
            ForEach(Array(segments(\.weeklyScoped).enumerated()), id: \.offset) { index, run in
                ForEach(run) { plot in
                    LineMark(
                        x: .value("When", plot.at),
                        y: .value("Per-model", plot.value),
                        series: .value("Scoped", "scoped-\(index)")
                    )
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                if run.count == 1, let only = run.first {
                    PointMark(
                        x: .value("When", only.at),
                        y: .value("Per-model", only.value)
                    )
                    .foregroundStyle(Color.purple)
                    .symbolSize(18)
                }
            }
            ForEach(projection(\.weeklyAll)) { plot in
                LineMark(
                    x: .value("When", plot.at),
                    y: .value("Used", plot.value),
                    series: .value("All", "all-projected")
                )
                .foregroundStyle(Color.accentColor.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
            ForEach(projection(\.weeklyScoped)) { plot in
                LineMark(
                    x: .value("When", plot.at),
                    y: .value("Per-model", plot.value),
                    series: .value("Scoped", "scoped-projected")
                )
                .foregroundStyle(Color.purple.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(resetMarks) { mark in
                RuleMark(x: .value("Resets", mark.at))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(mark.label).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var accessibilityText: String {
        let name = model.limitsAccountName(candidate.account)
        return "\(name): \(UsageOverview.reason(for: candidate, now: now))"
    }
}

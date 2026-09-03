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
            key(color: .purple, dash: [4, 3], text: "Per-model")
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

    /// The drawn line, **split at every gap**. A `nil` sample is a window the server did not
    /// report, and `UsageSeriesPoint` is explicit that this is a gap rather than a zero — but
    /// dropping those points with `compactMap` left Charts joining the samples on either side,
    /// drawing a straight run of usage through a stretch nothing was ever known about.
    private func segments(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [[Plot]] {
        var out: [[Plot]] = []
        var current: [Plot] = []
        for point in points {
            guard let value = point[keyPath: window] else {
                if !current.isEmpty { out.append(current) }
                current = []
                continue
            }
            current.append(Plot(at: point.at, value: value))
        }
        if !current.isEmpty { out.append(current) }
        return out
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
    /// It **ends where the window would run out**, when that comes first. Drawn only to the reset
    /// the endpoint is clamped to 1, so a quota heading for exhaustion on Friday was drawn
    /// reaching 100% on Sunday — the line said the right thing about the level and the wrong
    /// thing about the date, which is the half a timeline is read for.
    private func projection(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [Plot] {
        guard projectable(window), let resetsAt = reset(for: window), resetsAt > now,
              let last = history(window).last
        else { return [] }
        let periodStart = resetsAt.addingTimeInterval(-LimitEvaluator.sevenDayWindow)
        if let runsOut = UsageTrend.exhausts(
            of: window, in: points, before: resetsAt, since: periodStart
        ) {
            return [Plot(at: last.at, value: last.value), Plot(at: runsOut, value: 1)]
        }
        guard let ahead = UsageTrend.projected(
            of: window, in: points, at: resetsAt, since: periodStart
        ) else { return [] }
        return [Plot(at: last.at, value: last.value), Plot(at: resetsAt, value: ahead)]
    }

    /// Whether a forecast for this window would mean anything.
    ///
    /// `UsageSeriesPoint.weeklyScoped` is the highest scoped window **per sample**, so with more
    /// than one per-model quota the plotted line can change which model it represents partway
    /// through — and every such switch looks like a drop. Extrapolating that to one model's reset
    /// would be a forecast about a series no single quota followed, so none is drawn. The server
    /// sends one scoped window today, where this is exact.
    private func projectable(_ window: KeyPath<UsageSeriesPoint, Double?>) -> Bool {
        guard window == \.weeklyScoped else { return true }
        return (candidate.account.snapshot?.weeklyScoped.count ?? 0) == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            chart
                .frame(height: 62)
                .chartXScale(domain: range)
                .chartYScale(domain: 0 ... 1)
                .chartYAxis {
                    AxisMarks(values: [0, 1]) {
                        AxisGridLine()
                        AxisValueLabel(format: Decimal.FormatStyle.Percent.percent.scale(100))
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
            Text(UsageOverview.stateLabel(candidate.state))
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
                ForEach(run) { plot in
                    AreaMark(x: .value("When", plot.at), y: .value("Used", plot.value))
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
            // Only a reset still ahead is drawn: one that has passed is not a countdown, and the
            // ranking has already stopped reasoning from it.
            if let resetsAt = reset(for: \.weeklyAll), resetsAt > now, range.contains(resetsAt) {
                RuleMark(x: .value("Resets", resetsAt))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("resets").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var accessibilityText: String {
        let name = model.limitsAccountName(candidate.account)
        return "\(name): \(UsageOverview.reason(for: candidate, now: now))"
    }
}

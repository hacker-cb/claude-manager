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
            key(color: .accentColor, dashed: false, text: "All models")
            key(color: .purple, dashed: true, text: "Per-model")
            key(color: .secondary, dashed: true, text: "projected")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func key(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 14, height: 2)
                .opacity(dashed ? 0.6 : 1)
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
    private struct Plot: Identifiable {
        let id = UUID()
        let at: Date
        let value: Double
    }

    private func history(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [Plot] {
        points.compactMap { point in
            point[keyPath: window].map { Plot(at: point.at, value: $0) }
        }
    }

    /// The dashed continuation: from the last reading to the reset, at the rate the window has
    /// actually been spent since it last turned over.
    private func projection(_ window: KeyPath<UsageSeriesPoint, Double?>) -> [Plot] {
        guard let resetsAt = candidate.weeklyResetsAt, resetsAt > now,
              let last = history(window).last,
              let ahead = UsageTrend.projected(of: window, in: points, at: resetsAt)
        else { return [] }
        return [Plot(at: last.at, value: last.value), Plot(at: resetsAt, value: ahead)]
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
            ForEach(history(\.weeklyAll)) { plot in
                AreaMark(x: .value("When", plot.at), y: .value("Used", plot.value))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
            }
            ForEach(history(\.weeklyAll)) { plot in
                LineMark(x: .value("When", plot.at), y: .value("Used", plot.value))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(history(\.weeklyScoped)) { plot in
                LineMark(x: .value("When", plot.at), y: .value("Per-model", plot.value))
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            ForEach(projection(\.weeklyAll)) { plot in
                LineMark(x: .value("When", plot.at), y: .value("Projected", plot.value))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
            ForEach(projection(\.weeklyScoped)) { plot in
                LineMark(x: .value("When", plot.at), y: .value("Projected per-model", plot.value))
                    .foregroundStyle(Color.purple.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 1))
            // Only a reset still ahead is drawn: one that has passed is not a countdown, and the
            // ranking has already stopped reasoning from it.
            if let resetsAt = candidate.weeklyResetsAt, resetsAt > now, range.contains(resetsAt) {
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

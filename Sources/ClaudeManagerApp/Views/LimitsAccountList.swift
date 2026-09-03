import ClaudeManagerCore
import SwiftUI

/// The fleet in ranked order, with every window it has.
///
/// The order *is* the answer — the same ranking the cards read their leader from — so this is the
/// place someone checks the recommendation rather than takes it on trust: the bars beside each row
/// are what the decision was made from.
struct LimitsAccountList: View {
    @EnvironmentObject private var model: AppModel
    let now: Date

    /// Minimums that fit the narrowest window the app supports. At its 760pt floor the 240pt
    /// sidebar and 48pt of page padding leave roughly 470pt here, and the previous set already
    /// totalled 510 before spacing — so the last column was clipped, inside a `ScrollView` that
    /// only scrolls vertically and could not reach it.
    private let columns = [
        GridItem(.flexible(minimum: 104), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 62), alignment: .topLeading),
        GridItem(.flexible(minimum: 74), alignment: .topLeading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every account").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                heading("Account")
                heading("Session, 5h")
                heading("Week, all models")
                heading("Week, per-model")
                heading("Week resets")
                ForEach(model.limitsOverview(mode: model.limitsMode, now: now).candidates) { row in
                    account(row)
                    window(row.account.snapshot?.session, counted: true)
                    window(row.account.snapshot?.weeklyAll, counted: true)
                    scoped(row)
                    resets(row)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Who

    private func account(_ row: UsageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.limitsAccountName(row.account))
                .font(.callout).bold()
                .lineLimit(1)
            Text(UsageOverview.stateLabel(row.state))
                .font(.caption2)
                .foregroundStyle(row.canLead ? Color.accentColor : .secondary)
            // Every profile on this login, so a shared account says which windows it means.
            if row.account.bindingIDs.count > 1 {
                Text("shared with \(row.account.bindingIDs.count) profiles")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Windows

    /// One window as a bar plus its figure. `counted: false` dims the column rather than hiding
    /// it — the row stays the same shape in both modes, and a window that is simply not being
    /// counted right now is still a fact about the account.
    @ViewBuilder
    private func window(_ limit: UsageLimit?, counted: Bool) -> some View {
        if let limit {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(UsageFormat.percent(limit.utilization))
                        .font(.caption).bold().monospacedDigit()
                    Text(limit.shortLabel).font(.caption2).foregroundStyle(.secondary)
                }
                UsageBar(fraction: limit.utilization, height: 5, level: limit.displaySeverity)
            }
            .opacity(counted ? 1 : 0.4)
            .help(counted ? "" : "Not counted for \(model.limitsModeLabel(model.limitsMode))")
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func scoped(_ row: UsageCandidate) -> some View {
        let windows = row.account.snapshot?.weeklyScoped ?? []
        if windows.isEmpty {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, limit in
                    window(limit, counted: model.limitsMode == .scopedModel)
                }
            }
        }
    }

    // MARK: - When

    /// The clock time under the countdown — but only where there is one to give.
    ///
    /// `UsageFormat.resets` spells an absolute time beyond a day and returns a *relative* phrase
    /// under it, which stripped of its "resets " prefix read as a word-for-word repeat of the
    /// countdown directly above it.
    private func absoluteReset(_ resetsAt: Date) -> String? {
        guard resetsAt.timeIntervalSince(now) >= 24 * 3600 else { return nil }
        return UsageFormat.resets(resetsAt, now: now)?
            .replacingOccurrences(of: "resets ", with: "")
    }

    @ViewBuilder
    private func resets(_ row: UsageCandidate) -> some View {
        // The clock the ranking actually measured against, not a window's own field — the two
        // can differ, and showing the other one would explain a pace nobody computed.
        if let resetsAt = row.weeklyResetsAt, resetsAt > now {
            VStack(alignment: .leading, spacing: 2) {
                Text("in \(UsageFormat.compactDuration(resetsAt.timeIntervalSince(now)))")
                    .font(.caption).bold().monospacedDigit()
                if let absolute = absoluteReset(resetsAt) {
                    Text(absolute).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("unknown").font(.caption).foregroundStyle(.tertiary)
                .help("No live reset was reported for the window that binds this account.")
        }
    }
}

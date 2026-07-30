import ClaudeManagerCore
import SwiftUI

/// The full Usage section for a detail pane — bars for each limit plus extra-usage, mirroring
/// the CLI's `Settings/Usage.tsx`, with honest states (loading / login-needed / offline / stale)
/// and a manual refresh. Shown only when usage tracking is on (the parent gates that).
struct UsageDetailSection: View {
    let usage: AccountUsage?
    let failure: TokenProviderError?
    var isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        // One ticker for the whole section: every relative time inside it ("resets in 12m",
        // "updated 4 min ago") is derived from `now`, and without this they'd be frozen at
        // whatever the last usage refresh rendered — a countdown that doesn't count down.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                header(now: context.date)
                content(now: context.date)
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Usage").font(.headline)
            // The account's login lives in the pane header (identity, not statistics); this
            // section keeps only what's about the numbers themselves.
            if let usage, usage.bindingIDs.count > 1 {
                Text("· shared with \(usage.bindingIDs.count) profiles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let note = stateNote(now: now) {
                Text(note.text).font(.caption)
                    .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh usage")
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let snapshot = usage?.snapshot {
            bars(for: snapshot, now: now)
        } else if let note = emptyStateNote {
            // Tinted from the same flag the header used to carry: with no figures to date the
            // header stays quiet, so this sentence is the pane's only warning signal left.
            Text(note.text).font(.callout)
                .foregroundStyle(note.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        } else if isRefreshing {
            Text("Checking usage…").font(.callout).foregroundStyle(.secondary)
        } else {
            // "No data" is not "loading": a binding no refresh pass has covered yet — a launcher
            // added since the last check — has neither usage nor a failure to explain, and a
            // spinner-ish "Loading…" here would sit there forever. Say what's true and offer the
            // action that fixes it.
            Text("Not checked yet — use Refresh to fetch this account's usage.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bars(for snapshot: UsageSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = snapshot.session {
                LimitRow(title: "Current session (5h)", limit: session, now: now)
            }
            if let weekly = snapshot.weeklyAll {
                LimitRow(title: "Current week (all models)", limit: weekly, now: now)
            }
            // Keyed by position, not `dedupKey`: two scoped windows whose model name is missing
            // (or two unknown kinds sharing a rawKind) collapse to the same dedupKey, and a
            // duplicate ForEach id silently drops a row.
            //
            // Rendered whenever the server sent one, with no plan-shaped gate. `bindingLimit` —
            // what the sidebar ring and the menu bar quote — can pick a scoped window, and gating
            // the row here meant the headline number had no matching row anywhere in the pane.
            ForEach(Array(snapshot.weeklyScoped.enumerated()), id: \.offset) { _, scoped in
                LimitRow(
                    title: "Current week (\(scoped.scopeModelName ?? "scoped"))",
                    limit: scoped,
                    now: now
                )
            }
            // Forward-compat: a window this build doesn't recognize is kept visible (the parser's
            // "other" bucket) rather than silently dropped — so the detail can't disagree with the
            // sidebar, which may already be surfacing it as the binding limit.
            ForEach(Array(snapshot.otherLimits.enumerated()), id: \.offset) { _, other in
                LimitRow(title: other.shortLabel, limit: other, now: now)
            }
            if let extra = snapshot.extra {
                ExtraUsageRow(extra: extra)
            }
        }
    }

    /// The pane's header note and whether it warns — decided in core, painted here.
    private func stateNote(now: Date) -> (text: String, isWarning: Bool)? {
        UsagePresentation.headerNote(usage: usage, now: now)
    }

    /// When there's no snapshot to show, the sentence explaining why and whether it warns.
    private var emptyStateNote: (text: String, isWarning: Bool)? {
        UsagePresentation.sentence(usage: usage, failure: failure)
    }
}

/// One limit as a titled bar + `X% used · resets …`.
private struct LimitRow: View {
    let title: String
    let limit: UsageLimit
    /// Passed in rather than read from `Date()` so the whole section shares one ticking clock —
    /// see the `TimelineView` in `UsageDetailSection.body`.
    let now: Date

    /// The reset phrase to print beside the percentage, or nil to print none. Whether it may be
    /// printed at all is `UsagePresentation.showsReset` — the same rule the sidebar tooltip and the
    /// menu row now ask, so an elapsed window cannot read as "resetting…" on one surface and be
    /// silent on another.
    private var resets: String? {
        guard UsagePresentation.showsReset(limit.resetsAt, now: now) else { return nil }
        return UsageFormat.resets(limit.resetsAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            UsageBar(fraction: limit.utilization, level: limit.displaySeverity)
            HStack(spacing: 6) {
                Text("\(UsageFormat.percent(limit.utilization)) used").font(.caption)
                if let resets {
                    Text("· \(resets)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Extra-usage: a bar + `$X / $Y spent`, or "Unlimited" when there's no cap.
private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Extra usage").font(.callout)
            if !extra.isEnabled {
                Text("Not enabled").font(.caption).foregroundStyle(.secondary)
            } else if extra.isUnlimited {
                HStack(spacing: 6) {
                    Text("Unlimited").font(.caption)
                    Text(
                        "· \(UsageFormat.money(minorUnits: extra.usedMinor, currency: extra.currency)) spent"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if let limitMinor = extra.limitMinor {
                UsageBar(fraction: extra.displayUtilization ?? 0)
                Text("\(UsageFormat.money(minorUnits: extra.usedMinor, currency: extra.currency)) / "
                    + "\(UsageFormat.money(minorUnits: limitMinor, currency: extra.currency)) spent")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

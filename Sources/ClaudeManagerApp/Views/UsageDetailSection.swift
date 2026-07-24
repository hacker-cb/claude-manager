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
                    .foregroundStyle(note.warn ? Color.orange : Color.secondary)
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
            Text(note).font(.callout).foregroundStyle(.secondary)
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

    /// A short freshness/state note for the header: the data's age when current, otherwise the
    /// reason it's stale. Warning states (`warn`) are tinted so a still-rendered snapshot from a
    /// `loginNeeded` / `noSource` account can't read as up to date.
    private func stateNote(now: Date) -> (text: String, warn: Bool)? {
        guard let usage else { return nil }
        switch usage.state {
        case .fresh:
            return usage.snapshot?.capturedAt.map { ("updated \(UsageFormat.age($0, now: now))", false) }
        case let .stale(since): return ("stale · \(UsageFormat.age(since, now: now))", false)
        case .rateLimited: return ("rate limited", true)
        case .offline: return ("offline", false)
        case .loginNeeded: return ("sign in to refresh", true)
        // `.noSource` collapses every token-read failure, so the remedy comes from the actual
        // cause — a signed-out account must not be told to authorize the keychain.
        case .noSource: return (noSourceHeaderNote, true)
        }
    }

    /// A short header note for `.noSource`, keyed on why the token couldn't be read.
    private var noSourceHeaderNote: String {
        switch failure {
        case .noTokenCache: "not signed in"
        case .keychainUnavailable: "authorize keychain access"
        default: "source unavailable"
        }
    }

    /// When there's no snapshot to show, the reason (login-needed / no-source / a token failure).
    private var emptyStateNote: String? {
        if let usage {
            switch usage.state {
            case .loginNeeded: return "Sign in to this account in Claude to see usage."
            case .noSource: return noSourceEmptyNote
            case .offline: return "Offline — no usage yet."
            default: return nil
            }
        }
        switch failure {
        case .noTokenCache: return "This account isn't signed in on this profile."
        case .keychainUnavailable: return "Refresh to authorize keychain access."
        case .some: return "Usage unavailable for this account."
        case nil: return nil
        }
    }

    /// The full-sentence `.noSource` note, keyed on the token-read failure — a signed-out account
    /// reads "not signed in", not the keychain prompt that can't fix it.
    private var noSourceEmptyNote: String {
        switch failure {
        case .noTokenCache: "This account isn't signed in on this profile."
        case .keychainUnavailable:
            "Usage source unavailable — open Claude Manager and refresh to authorize keychain access."
        default: "Usage source unavailable for this account."
        }
    }
}

/// One limit as a titled bar + `X% used · resets …`.
private struct LimitRow: View {
    let title: String
    let limit: UsageLimit
    /// Passed in rather than read from `Date()` so the whole section shares one ticking clock —
    /// see the `TimelineView` in `UsageDetailSection.body`.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            UsageBar(fraction: limit.utilization, level: limit.displaySeverity)
            HStack(spacing: 6) {
                Text("\(UsageFormat.percent(limit.utilization)) used").font(.caption)
                if let resets = UsageFormat.resets(limit.resetsAt, now: now) {
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
                UsageBar(fraction: extra.utilization ?? (Double(extra.usedMinor) / Double(max(
                    1,
                    limitMinor
                ))))
                Text("\(UsageFormat.money(minorUnits: extra.usedMinor, currency: extra.currency)) / "
                    + "\(UsageFormat.money(minorUnits: limitMinor, currency: extra.currency)) spent")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

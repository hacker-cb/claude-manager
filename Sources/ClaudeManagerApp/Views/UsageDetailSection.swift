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
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Usage").font(.headline)
            if let usage, usage.bindingIDs.count > 1 {
                Text("· shared with \(usage.bindingIDs.count) profiles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let note = stateNote {
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
    private var content: some View {
        if let snapshot = usage?.snapshot {
            bars(for: snapshot)
        } else if let note = emptyStateNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Loading usage…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bars(for snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = snapshot.session {
                LimitRow(title: "Current session (5h)", limit: session)
            }
            if let weekly = snapshot.weeklyAll {
                LimitRow(title: "Current week (all models)", limit: weekly)
            }
            if usage?.identity.showsScopedWeeklyLimit == true {
                ForEach(snapshot.weeklyScoped, id: \.dedupKey) { scoped in
                    LimitRow(title: "Current week (\(scoped.scopeModelName ?? "scoped"))", limit: scoped)
                }
            }
            // Forward-compat: a window this build doesn't recognize is kept visible (the parser's
            // "other" bucket) rather than silently dropped — so the detail can't disagree with the
            // sidebar, which may already be surfacing it as the binding limit.
            ForEach(snapshot.otherLimits, id: \.dedupKey) { other in
                LimitRow(title: other.shortLabel, limit: other)
            }
            if let extra = snapshot.extra {
                ExtraUsageRow(extra: extra)
            }
        }
    }

    /// A short freshness/state note for the header: the data's age when current, otherwise the
    /// reason it's stale. Warning states (`warn`) are tinted so a still-rendered snapshot from a
    /// `loginNeeded` / `noSource` account can't read as up to date.
    private var stateNote: (text: String, warn: Bool)? {
        guard let usage else { return nil }
        switch usage.state {
        case .fresh:
            return usage.snapshot?.capturedAt.map { ("updated \(UsageFormat.age($0))", false) }
        case let .stale(since): return ("stale · \(UsageFormat.age(since))", false)
        case .rateLimited: return ("rate limited", true)
        case .offline: return ("offline", false)
        case .loginNeeded: return ("sign in to refresh", true)
        case .noSource: return ("authorize keychain access", true)
        }
    }

    /// When there's no snapshot to show, the reason (login-needed / no-source / a token failure).
    private var emptyStateNote: String? {
        if let usage {
            switch usage.state {
            case .loginNeeded: return "Sign in to this account in Claude to see usage."
            case .noSource: return "Usage source unavailable — open Claude Manager and refresh to authorize keychain access."
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
}

/// One limit as a titled bar + `X% used · resets …`.
private struct LimitRow: View {
    let title: String
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            UsageBar(fraction: limit.utilization)
            HStack(spacing: 6) {
                Text("\(UsageFormat.percent(limit.utilization)) used").font(.caption)
                if let resets = UsageFormat.resets(limit.resetsAt) {
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

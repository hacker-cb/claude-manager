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
            if let subtitle = freshnessSubtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
            if let extra = snapshot.extra {
                ExtraUsageRow(extra: extra)
            }
        }
    }

    /// A short freshness/state note for the header (age when stale, reason otherwise).
    private var freshnessSubtitle: String? {
        guard let usage else { return nil }
        switch usage.state {
        case .fresh: return usage.snapshot?.capturedAt.map { "updated \(UsageFormat.age($0))" }
        case let .stale(since): return "stale · \(UsageFormat.age(since))"
        case .rateLimited: return "rate limited"
        case .offline: return "offline"
        case .loginNeeded, .noSource: return nil
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

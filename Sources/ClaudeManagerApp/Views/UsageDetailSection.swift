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

    /// Whether these figures are still moving. Drives the reset countdown — see `LimitRow`.
    private var isLive: Bool {
        usage?.isQuotableNow == true
    }

    private func bars(for snapshot: UsageSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = snapshot.session {
                LimitRow(title: "Current session (5h)", limit: session, now: now, isLive: isLive)
            }
            if let weekly = snapshot.weeklyAll {
                LimitRow(title: "Current week (all models)", limit: weekly, now: now, isLive: isLive)
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
                    now: now,
                    isLive: isLive
                )
            }
            // Forward-compat: a window this build doesn't recognize is kept visible (the parser's
            // "other" bucket) rather than silently dropped — so the detail can't disagree with the
            // sidebar, which may already be surfacing it as the binding limit.
            ForEach(Array(snapshot.otherLimits.enumerated()), id: \.offset) { _, other in
                LimitRow(title: other.shortLabel, limit: other, now: now, isLive: isLive)
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
        // A binding that failed with no snapshot to keep carries no `AccountUsage` at all — and
        // used to get no note either, so the pane fell silent in the very state it had most to say
        // about. Its failure is the whole story there.
        guard let usage else { return failure.map(Self.headerNote) }
        switch usage.state {
        case .fresh:
            return usage.snapshot?.capturedAt.map { ("updated \(UsageFormat.age($0, now: now))", false) }
        case let .stale(since): return ("stale · \(UsageFormat.age(since, now: now))", false)
        case .rateLimited: return ("rate limited", true)
        case .offline: return ("offline", false)
        case .loginNeeded: return ("sign in to refresh", true)
        // `.noSource` collapses every token-read failure, so the remedy comes from the cause it
        // carries — a signed-out account must not be told to authorize the keychain.
        //
        // Dated, always. These bars are a carried-forward reading whose account we can no longer
        // reach, and every other cue that they have stopped moving is gone here: `.fresh`'s
        // "updated N min ago" doesn't render, the countdown is dropped once the window elapses, and
        // a signed-out profile is deliberately not tinted. Without the age, a day-old 87% reads as
        // the current quota.
        case let .noSource(reason):
            let note = Self.headerNote(reason)
            guard let capturedAt = usage.snapshot?.capturedAt else { return note }
            return ("\(note.text) · as of \(UsageFormat.age(capturedAt, now: now))", note.warn)
        }
    }

    /// A short header note for a token-read failure, and whether it reads as a warning.
    ///
    /// Signing out is deliberately **not** one. `warn` exists to stop still-rendered figures from
    /// passing as current, and nothing here is broken — the user did this on purpose. Spending the
    /// warning colour on a non-warning is how a warning colour stops meaning anything; the keychain
    /// arms, which are genuine malfunctions, keep it.
    private static func headerNote(_ failure: TokenProviderError) -> (text: String, warn: Bool) {
        switch failure {
        case .signedOut: ("signed out", false)
        case .noTokenCache: ("not signed in", false)
        case let .keychainUnavailable(error):
            switch keychainNoteKind(error) {
            case .authorize: ("authorize keychain access", true)
            case .missing: ("keychain item missing", true)
            case .error: ("keychain error", true)
            }
        default: ("source unavailable", true)
        }
    }

    /// When there's no snapshot to show, the reason (login-needed / no-source / a token failure).
    private var emptyStateNote: String? {
        if let usage {
            switch usage.state {
            case .loginNeeded: return "Sign in to this account in Claude to see usage."
            case let .noSource(reason): return Self.emptySentence(reason)
            case .offline: return "Offline — no usage yet."
            // Without this the header says "rate limited" while the body falls through to "Not
            // checked yet — use Refresh", which contradicts it and points at a Refresh that is
            // itself inside the backoff.
            case .rateLimited: return "Rate limited — usage will refresh once the window clears."
            default: return nil
            }
        }
        return failure.map(Self.emptySentence)
    }

    /// The full-sentence note for a token-read failure — the state named, and a remedy that can
    /// actually fix it.
    ///
    /// Reached in practice only through the no-entry path: `UsageService.merge` produces
    /// `.noSource` solely for a binding that had a snapshot to carry, so the `.noSource` arm above
    /// is the defensive half of the pair and does not render today. One table for both anyway —
    /// they were two near-identical switches free to drift on a word, and the invariant that keeps
    /// one of them quiet lives in another module.
    private static func emptySentence(_ failure: TokenProviderError) -> String {
        switch failure {
        case .signedOut: "Signed out — open Claude on this profile and sign in to see usage."
        case .noTokenCache: "This account isn't signed in on this profile."
        case let .keychainUnavailable(error):
            switch keychainNoteKind(error) {
            case .authorize:
                "Usage source unavailable — open Claude Manager and refresh to authorize keychain access."
            case .missing: keychainNotFoundNote
            case .error: "Usage source unavailable — a keychain error blocked the token."
            }
        default: "Usage unavailable for this account."
        }
    }

    /// A missing keychain item can't be authorized — Refresh won't prompt — so point at the real
    /// cause: Claude Desktop's safeStorage item isn't present for this profile.
    private static let keychainNotFoundNote =
        "Claude's keychain item wasn't found — open Claude and sign in on this profile, then Refresh."

    /// The user-facing category of a keychain failure, classified in one place so the notes above
    /// can't drift on which `KeychainError` means what — only the copy differs by context.
    private static func keychainNoteKind(_ error: KeychainError) -> KeychainNoteKind {
        switch error {
        case .interactionNotAllowed: .authorize
        case .notFound: .missing
        case .unexpected: .error
        }
    }
}

/// How a keychain read failure reads to the user: a fixable access refusal (`authorize`), a missing
/// item (`missing`), or a genuine malfunction (`error`). One classification, three context copies.
private enum KeychainNoteKind {
    case authorize
    case missing
    case error
}

/// One limit as a titled bar + `X% used · resets …`.
private struct LimitRow: View {
    let title: String
    let limit: UsageLimit
    /// Passed in rather than read from `Date()` so the whole section shares one ticking clock —
    /// see the `TimelineView` in `UsageDetailSection.body`.
    let now: Date
    /// Whether the percentage beside the countdown is still moving.
    let isLive: Bool

    /// The reset phrase to print beside the percentage, or nil to print none.
    ///
    /// Printed while the window is still ahead, whatever the account's state: that timestamp is the
    /// server's own and stays true through a stale or rate-limited pass, where on a near-full
    /// weekly row it is the most useful figure there is.
    ///
    /// Dropped once the window has elapsed on figures that are no longer moving.
    /// `UsageFormat.resets` says "resetting…" for an elapsed window — true of a fresh reading, and
    /// a permanent, ticking lie for a carried-forward one whose window reset hours ago. The header
    /// carries the state and the age instead.
    private var resets: String? {
        guard let resetsAt = limit.resetsAt, isLive || resetsAt > now else { return nil }
        return UsageFormat.resets(resetsAt, now: now)
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

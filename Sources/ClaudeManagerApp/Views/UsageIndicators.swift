import ClaudeManagerCore
import SwiftUI

/// The app-layer painting of core's `UsageSeverity`. The severity itself is decided in core and
/// unit-tested there — `UsageLimit.displaySeverity` for a real limit (folding in the server's own
/// flag), `UsageLimit.thresholdSeverity(_:)` for a bare fraction (a money bar with no server
/// severity, like extra usage) — so this layer only paints it, never re-derives it.
///
/// Severity is never carried by colour alone, but the second channel is the **figure**, not a
/// glyph: every surface that tints by severity prints the percentage right beside it — the
/// sidebar's `UsageAccessory` and the detail pane's `LimitRow` both do — and "100%" separates the
/// states more finely than an amber-vs-red icon ever did. The glyph that used to sit here bought
/// no resolution the number didn't already have, and cost the sidebar its alignment: as a
/// conditional first child it shoved every warning row's figures sideways.
///
/// `LimitEvaluator` is deliberately not folded into the display severity: its lowest trigger (0.75
/// on the weekly tier) is exactly where these thresholds already warn and it is more lenient
/// elsewhere, so it could never escalate a bar — the notification model is the quieter of the
/// two by design, since "worth showing" is a lower bar than "worth interrupting you".
extension UsageSeverity {
    /// For a bar in the detail pane, which sits on the pane's own background and can afford a
    /// literal accent fill. A compact row inside a `List` cannot — see `UsageAccessory.tint`.
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A determinate usage bar: a track with a severity-colored fill. Used in the detail Usage
/// section and (compactly) elsewhere.
struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = 6
    /// Explicit severity for a real `UsageLimit` (which can be escalated by the API); nil falls
    /// back to the plain fraction thresholds, which is what extra-usage — a money bar with no
    /// server severity of its own — wants.
    var level: UsageSeverity?

    private var severity: UsageSeverity {
        level ?? UsageLimit.thresholdSeverity(fraction)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        // Clamp like the fill: `fraction` can exceed 1 (e.g. extra-usage's used÷cap with a zero
        // cap), which the bar renders as full — VoiceOver must announce that, not "5000% used".
        .accessibilityLabel("\(Int((min(1, max(0, fraction)) * 100).rounded()))% used")
    }
}

/// The sidebar row's single trailing accessory: one fixed-width, right-aligned cell.
///
/// One fixed width, claimed by every row with a tracked account — that is the whole fix. What
/// stood here before was a `VStack(alignment: .trailing)` of children whose widths differed by an
/// order of magnitude, so the only thing that ever agreed between rows was the right edge, which
/// is not where the eye starts reading. A single cell makes the figures a column you can run down.
/// See `body` for exactly when the width is claimed and when it isn't.
///
/// Text rather than a ring, because `UsageSnapshot.bindingLimit` picks the highest-utilization
/// *active* window per account: one row's 97% can be a 5h window and the next row's a weekly one.
/// A bare arc invites a comparison those different denominators can't support; `7d 97%` says what
/// the number is a percentage of.
struct UsageAccessory: View {
    let usage: AccountUsage?

    /// Wide enough for the longest thing the cell prints — a clamped window label plus a
    /// three-digit percentage (`7d·Fa… 100%`).
    static let width: CGFloat = 66

    var body: some View {
        // The cell exists for an account that is being tracked, whether or not it has numbers yet:
        // one that is offline with no stored sample, or whose first fetch hasn't landed, still
        // holds its width so the figures don't shove their neighbours around when they arrive.
        //
        // No cell at all when there is no `AccountUsage` — tracking switched off (the store is
        // cleared, so every row is nil) or no refresh pass has reached this binding. Reserving
        // unconditionally cost a 240pt sidebar a quarter of its identity column in the one
        // configuration where the column can never fill, and left a `TimelineView` ticking once a
        // minute per row forever, in a menu-bar utility whose user had just asked it to stop
        // reading usage. A binding the first pass hasn't covered — a launcher added since the last
        // check — is the one case that still settles once, when its account appears.
        if let usage {
            content(usage)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                // Shrink rather than truncate: an ellipsis in a number is worse than a slightly
                // smaller one, and only the rare scoped-window label ever reaches this.
                .minimumScaleFactor(0.85)
                .frame(width: Self.width, alignment: .trailing)
                // The whole reserved cell is the hover target, not the glyph-width of the figure
                // inside it. `7d 85%` is around 40pt of a 66pt column pinned to the row's trailing
                // edge, so a tooltip attached to the text alone has to be hit almost exactly — the
                // reset countdown lives in there and is the reason to hover at all.
                .contentShape(Rectangle())
                // Recomputed each minute so the countdown inside is live: a tooltip built once at
                // render would still read "resets in 29m" half an hour later.
                .modifier(LiveHelp { helpText(usage: usage, now: $0) })
        }
    }

    @ViewBuilder
    private func content(_ usage: AccountUsage) -> some View {
        // Attention replaces the figure rather than dimming it: a `loginNeeded` / `noSource`
        // account can still carry a stale snapshot (so `displayLimit` is non-nil), and a
        // plausible-looking percentage there hides the action the user has to take. The stale
        // numbers stay available in the detail pane.
        if let word = usage.attentionWord {
            Text(word).foregroundStyle(.orange)
        } else if let limit = usage.displayLimit {
            Text("\(limit.compactLabel) \(UsageFormat.percent(limit.utilization))")
                .foregroundStyle(tint(limit.displaySeverity))
                // Spelled out, from the *unclamped* label, and qualified when the figure has
                // stopped moving: "7d 85%" read literally is a string of letters, the cell's clamp
                // is a width concession VoiceOver doesn't share, and the dimming that tells a
                // sighted user the number is frozen is invisible to a screen reader — which would
                // otherwise hear an hour-old percentage announced as the current one.
                .accessibilityLabel(accessibilityLabel(limit: limit, usage: usage))
                // Dimmed once the number has stopped moving: a frozen figure drawn at full
                // strength reads as live. The tooltip names the state.
                .opacity(usage.isQuotableNow ? 1 : 0.55)
        }
    }

    private func accessibilityLabel(limit: UsageLimit, usage: AccountUsage) -> String {
        let figure = "\(limit.shortLabel) window, \(UsageFormat.percent(limit.utilization)) used"
        return usage.isQuotableNow ? figure : "\(figure), \(usage.stateNote)"
    }

    /// The cell's tooltip, or nil when there is nothing to say — an empty `.help` would arm a
    /// hover target that pops a blank box.
    private func helpText(usage: AccountUsage, now: Date) -> String? {
        if usage.attentionWord != nil { return usage.stateNote }
        guard let limit = usage.displayLimit else { return nil }
        return tooltip(limit: limit, usage: usage, now: now)
    }

    /// Normal is *hierarchical*, not a literal colour, and that is the point: a selected sidebar
    /// row is filled with the accent-derived selection colour, so the old `.accentColor` normal
    /// state was painted onto its own background and vanished — on the one row the user is
    /// looking at, in the state most rows are in. `.secondary` inverts with the selection;
    /// amber and red are meant to stand out against it.
    private func tint(_ severity: UsageSeverity) -> AnyShapeStyle {
        switch severity {
        case .normal: AnyShapeStyle(.secondary)
        case .warning: AnyShapeStyle(Color.orange)
        case .critical: AnyShapeStyle(Color.red)
        }
    }

    private func tooltip(limit: UsageLimit, usage: AccountUsage, now: Date) -> String {
        var parts: [String] = []
        if let account = usage.identity.accountLabel { parts.append(account) }
        parts.append("\(limit.shortLabel): \(UsageFormat.percent(limit.utilization)) used")
        if let resets = UsageFormat.resets(limit.resetsAt, now: now) { parts.append(resets) }
        // Qualify any not-current state, not just `.stale`: a rate-limited or offline account still
        // shows its last-known percentage, and an unqualified number there reads as live — the same
        // discipline `isQuotableNow` applies on the menu bar.
        switch usage.state {
        case let .stale(since): parts.append("as of \(UsageFormat.age(since, now: now))")
        case .rateLimited: parts.append("rate limited")
        case .offline: parts.append("offline")
        case .fresh, .loginNeeded, .noSource: break
        }
        return parts.joined(separator: " · ")
    }
}

/// Re-evaluates a `.help` tooltip once a minute.
///
/// Every relative time in this app ("resets in 12m", "updated 4 min ago") is computed from `Date()`
/// at render, but SwiftUI only re-renders on state change — and usage state changes every 5–30
/// minutes. Left alone, a countdown freezes on screen and then jumps, which reads as a live timer
/// that is quietly lying. A minute ticker costs nothing here and keeps it honest.
struct LiveHelp: ViewModifier {
    /// nil for "no tooltip here" — a surface that reserves its space whether or not it has
    /// anything to say must not arm a hover target that pops an empty box.
    let text: (Date) -> String?

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let text = text(context.date) {
                content.help(text)
            } else {
                content
            }
        }
    }
}

// MARK: - Formatting

enum UsageFormat {
    /// `42%` from a fraction.
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// `7d 54%` — the one spelling of a limit's compact label, shared by the sidebar row, the
    /// menu-bar status item, and each menu account row, so the three can't drift apart.
    static func limitSummary(_ limit: UsageLimit) -> String {
        "\(limit.shortLabel) \(percent(limit.utilization))"
    }

    /// Reused across renders — building a `DateFormatter` / `NumberFormatter` resolves the
    /// locale each time, and these are called from view bodies and tooltips that re-render
    /// often. `@MainActor` (not a bare `static let`) is what makes sharing mutable formatters
    /// safe under strict concurrency; every caller is already main-actor UI code.
    @MainActor private static let dateFormatter = DateFormatter()
    @MainActor private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter
    }()

    /// A short reset phrase: `resets in 3h 10m` under a day, else `resets Thu 10:59 AM` /
    /// `resets Jul 28`. nil when there's no reset time.
    @MainActor
    static func resets(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "resetting…" }
        // Under a minute both hours and minutes floor to 0, which would read "resets in 0m"; say
        // "<1m" for that last minute instead.
        if seconds < 60 { return "resets in <1m" }
        if seconds < 24 * 3600 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
        }
        let formatter = dateFormatter
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(seconds < 7 * 24 * 3600 ? "EEE h:mm a" : "MMM d")
        return "resets \(formatter.string(from: date))"
    }

    /// `$1,000.00` from minor units (cents).
    @MainActor
    static func money(minorUnits: Int, currency: String = "USD") -> String {
        let formatter = currencyFormatter
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: Double(minorUnits) / 100)) ?? "\(minorUnits)"
    }

    /// "3 min ago" / "just now" for a captured-at timestamp.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 3600 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}

// MARK: - AccountUsage display helpers

extension AccountUsage {
    /// The limit that constrains the account right now (highest-utilization active window).
    var displayLimit: UsageLimit? {
        snapshot?.bindingLimit
    }

    /// Whether the numbers are current enough to quote as a bare percentage on a compact surface
    /// (the menu bar, a menu row). Anything else — stale, offline, rate-limited, needing a
    /// sign-in — is shown as its state instead: a frozen figure with a live countdown beside it
    /// reads as live, and there is no room there to say otherwise.
    var isQuotableNow: Bool {
        state == .fresh
    }

    /// Whether the account needs a user action (a re-login / authorization) — surfaced even
    /// without a snapshot to show.
    var needsAttention: Bool {
        attentionWord != nil
    }

    /// The word a compact cell prints instead of a percentage when the account needs the user —
    /// nil when it doesn't.
    ///
    /// Only `.loginNeeded` names an action, because it is the only one we can name: the API
    /// rejected the token, so signing in is genuinely the fix. `.noSource` collapses a locked
    /// keychain, a missing keychain item and an absent token cache, whose remedies differ and
    /// none of which is a sign-in — telling that user to sign in sends them to do the one thing
    /// that cannot help. This cell has no `TokenProviderError` to tell them apart (the detail
    /// pane does, and words each case), so it stays honest by not instructing at all.
    var attentionWord: String? {
        switch state {
        case .loginNeeded: "Sign in"
        case .noSource: "Unavailable"
        case .fresh, .stale, .rateLimited, .offline: nil
        }
    }

    /// Human phrase for a non-fresh state, for tooltips / placeholders.
    var stateNote: String {
        switch state {
        case .fresh: "up to date"
        case let .stale(since): "as of \(UsageFormat.age(since))"
        case .loginNeeded: "login needed"
        case .rateLimited: "rate limited"
        case .noSource: "not available"
        case .offline: "offline"
        }
    }
}

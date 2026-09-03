import Foundation

/// Severity of a usage window, as reported by the API's `severity` string.
///
/// `Comparable` so callers can pick the *most* severe of several limits; parsing is
/// lenient (an unknown or missing value degrades to `.normal`) because the field is a
/// forward-evolving enum on a reverse-engineered surface.
public enum UsageSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case normal
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Map an API `severity` string (any case) to a known value; anything unrecognized
    /// or absent is `.normal` — never a decode failure.
    public static func parse(_ raw: String?) -> UsageSeverity {
        guard let raw, let value = UsageSeverity(rawValue: raw.lowercased()) else { return .normal }
        return value
    }
}

/// One rate-limit window from the `/api/oauth/usage` `limits[]` array — the
/// forward-compatible source of truth. `rawKind` is kept verbatim so an unknown kind
/// (a window Anthropic adds later) is preserved rather than dropped; the `is…`
/// helpers classify the known kinds without hard-coding a closed enum.
///
/// `utilization` is normalized to a **fraction 0…1** at parse time (the API reports a
/// percent 0…100), so every internal comparison — thresholds, the binding-limit pick —
/// speaks one unit. The scoped-model label lives in `scopeModelName` (e.g. "Fable"),
/// because the per-model weekly limit's model is *data*, not a field name.
public struct UsageLimit: Codable, Sendable, Equatable {
    public var rawKind: String
    public var group: String?
    /// Fraction 0…1 (API percent ÷ 100, clamped).
    public var utilization: Double
    public var resetsAt: Date?
    public var severity: UsageSeverity
    public var isActive: Bool
    /// `scope.model.display_name` for a `weekly_scoped` window (e.g. "Fable"); nil otherwise.
    public var scopeModelName: String?

    public static let kindSession = "session"
    public static let kindWeeklyAll = "weekly_all"
    public static let kindWeeklyScoped = "weekly_scoped"

    public init(
        rawKind: String,
        group: String? = nil,
        utilization: Double,
        resetsAt: Date? = nil,
        severity: UsageSeverity = .normal,
        isActive: Bool = false,
        scopeModelName: String? = nil
    ) {
        self.rawKind = rawKind
        self.group = group
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
        self.scopeModelName = scopeModelName
    }

    public var isSession: Bool {
        rawKind == UsageLimit.kindSession
    }

    public var isWeeklyAll: Bool {
        rawKind == UsageLimit.kindWeeklyAll
    }

    public var isWeeklyScoped: Bool {
        rawKind == UsageLimit.kindWeeklyScoped
    }

    /// False for a kind this build doesn't recognize — the "other" bucket that keeps
    /// a forward-version window visible instead of silently dropping it.
    public var isKnownKind: Bool {
        isSession || isWeeklyAll || isWeeklyScoped
    }

    /// Short surface label: `5h`, `7d`, `7d·<Model>`, or the raw kind for an unknown window.
    public var shortLabel: String {
        if isSession { return "5h" }
        if isWeeklyAll { return "7d" }
        if isWeeklyScoped { return "7d·\(scopeModelName ?? "?")" }
        return rawKind
    }

    /// `shortLabel` clamped for a fixed-width surface. The sidebar reserves one column for the
    /// label + percentage, and `shortLabel` can be an arbitrary server string — a `rawKind` for a
    /// window this build doesn't recognize, or a long model name in a scoped one — which would
    /// either overflow that column or push it around.
    ///
    /// The ellipsis is not decoration. A bare `prefix` turns `weekly_opus` and `weekly_sonnet`
    /// into the same plausible-looking word, which reads as one window named "weekly" rather than
    /// as an abbreviation — and the menu bar, which prints the full `shortLabel`, then looks like
    /// it is talking about a different limit. Marking the cut keeps the two surfaces legible as
    /// the same thing at two widths; the full label stays in the tooltip and the VoiceOver label.
    public var compactLabel: String {
        let full = shortLabel
        return full.count <= 6 ? full : String(full.prefix(5)) + "…"
    }

    /// Utilization at which a surface turns amber, then red. Deliberately stricter than
    /// `LimitEvaluator`'s notification model: colour answers "how full is this?", which is worth
    /// showing before it's worth interrupting someone over.
    public static let warningUtilization = 0.75
    public static let criticalUtilization = 0.90

    /// The severity to **render** for this limit: our own thresholds, escalated by the server's
    /// `severity` but never lowered to it.
    ///
    /// Both directions matter. The server can flag something we have no model for — a plan
    /// policy, an account restriction, or a `kind` this build doesn't recognize, where a flat
    /// percentage means little — and taking the max lets that flag make a surface more cautious.
    /// It currently reports `normal` well past 70%, so the reverse must not happen: a server
    /// "normal" can't calm a bar we already consider hot.
    public var displaySeverity: UsageSeverity {
        max(Self.thresholdSeverity(utilization), severity)
    }

    /// The threshold half on its own, for a bar with no limit behind it (extra usage).
    public static func thresholdSeverity(_ utilization: Double) -> UsageSeverity {
        if utilization >= criticalUtilization { return .critical }
        if utilization >= warningUtilization { return .warning }
        return .normal
    }

    /// Stable identity for notification dedup — distinguishes a scoped window per model
    /// (`weekly_scoped:Fable`) from the weekly-all window, so they don't share a ledger key.
    public var dedupKey: String {
        isWeeklyScoped ? "\(rawKind):\(scopeModelName ?? "")" : rawKind
    }
}

/// Extra-usage (overage) credits. Amounts are **minor units (cents)** — the API reports
/// `used_credits`/`monthly_limit` in cents. `limitMinor == nil` means *no cap*
/// (unlimited), rendered without a progress bar; `utilization` is then nil (nothing to
/// divide by).
public struct ExtraUsage: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Credits spent, in minor units (cents).
    public var usedMinor: Int
    /// Monthly cap in minor units (cents); nil = unlimited.
    public var limitMinor: Int?
    /// Fraction 0…1; nil when unlimited or not reported.
    public var utilization: Double?
    public var currency: String

    public init(
        isEnabled: Bool,
        usedMinor: Int,
        limitMinor: Int?,
        utilization: Double?,
        currency: String
    ) {
        self.isEnabled = isEnabled
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.utilization = utilization
        self.currency = currency
    }

    /// Enabled with no cap — show "Unlimited", never a bar.
    public var isUnlimited: Bool {
        isEnabled && limitMinor == nil
    }

    /// The fraction to fill the extra-usage bar: the server's `utilization` when reported, else
    /// used ÷ cap (guarding a zero cap). Nil when there's no cap to measure against (unlimited /
    /// unreported), so the view knows not to draw a bar. Keeps the used÷limit math (and its
    /// divide-by-zero guard) in one tested place instead of a SwiftUI body.
    public var displayUtilization: Double? {
        guard let limitMinor else { return nil }
        return utilization ?? (Double(usedMinor) / Double(max(1, limitMinor)))
    }
}

/// A parsed, unit-normalized snapshot of one account's plan usage. `limits` is the
/// canonical source of truth (all kinds preserved, including unknown ones); the typed
/// accessors are conveniences over it. `capturedAt` is stamped by the caller (the API
/// body carries no capture time), so the parser leaves it nil.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var limits: [UsageLimit]
    public var extra: ExtraUsage?
    public var capturedAt: Date?

    public init(limits: [UsageLimit], extra: ExtraUsage? = nil, capturedAt: Date? = nil) {
        self.limits = limits
        self.extra = extra
        self.capturedAt = capturedAt
    }

    /// Whether there is anything here to show.
    ///
    /// Not the same question as the snapshot existing. `UsageLimitsParser.parse(object:)` always
    /// succeeds — an empty or odd body yields a snapshot with no limits at all, so that a partial
    /// response never crashes a background poll — and such a snapshot renders no bars, dates no
    /// header and answers no ranking.
    ///
    /// `extra` deliberately does not count: extra usage is money rather than a window, and
    /// nothing on the limits surfaces reads it.
    public var hasFigures: Bool {
        !limits.isEmpty
    }

    public var session: UsageLimit? {
        limits.first(where: \.isSession)
    }

    public var weeklyAll: UsageLimit? {
        limits.first(where: \.isWeeklyAll)
    }

    public var weeklyScoped: [UsageLimit] {
        limits.filter(\.isWeeklyScoped)
    }

    /// Windows this build doesn't recognize — kept visible, never dropped.
    public var otherLimits: [UsageLimit] {
        limits.filter { !$0.isKnownKind }
    }

    /// The limit that actually constrains the user right now: the highest-utilization
    /// **active** window (falling back to the overall highest when nothing is marked
    /// active). This is what the sidebar and menu-bar surfaces show, so the fast-moving
    /// window about to bite is the one displayed — not a fixed 7d.
    ///
    /// The fallback is display-only: `LimitEvaluator.warnings` deliberately does *not* mirror it,
    /// so an all-inactive snapshot can still show a number without also raising a notification for
    /// a window the server marked inactive.
    public var bindingLimit: UsageLimit? {
        let active = limits.filter(\.isActive)
        let pool = active.isEmpty ? limits : active
        return pool.max { $0.utilization < $1.utilization }
    }
}

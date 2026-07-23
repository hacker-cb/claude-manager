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
    public var bindingLimit: UsageLimit? {
        let active = limits.filter(\.isActive)
        let pool = active.isEmpty ? limits : active
        return pool.max { $0.utilization < $1.utilization }
    }
}

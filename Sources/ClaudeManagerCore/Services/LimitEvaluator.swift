import Foundation

/// A usage limit that warrants a reminder. `limitKey` is the notification-dedup identity;
/// `threshold` is the tier that fired (so the ledger can re-notify when a higher tier trips).
public struct UsageWarning: Sendable, Equatable {
    public var limitKey: String
    public var limitLabel: String
    public var utilization: Double
    public var severity: UsageSeverity
    public var threshold: Double
    public var resetsAt: Date?

    public init(
        limitKey: String,
        limitLabel: String,
        utilization: Double,
        severity: UsageSeverity,
        threshold: Double,
        resetsAt: Date?
    ) {
        self.limitKey = limitKey
        self.limitLabel = limitLabel
        self.utilization = utilization
        self.severity = severity
        self.threshold = threshold
        self.resetsAt = resetsAt
    }
}

/// Decides which limits in a snapshot warrant a warning, combining two models (pure — no I/O,
/// no dedup; the ledger + delivery live in the notifications slice):
///
/// - **Time-relative** (reverse-engineered from the CLI's `claudeAiLimits.ts`): warn when usage
///   is burning faster than the window elapses — `utilization ≥ tier.util AND timeProgress ≤
///   tier.timePct`. Catches a steady-but-fast burn early. Suppressed below a 0.70 floor (guards
///   against stale post-reset data), which is why the tiers kept here all sit above it.
/// - **Absolute near-exhaustion**: warn at ≥ 0.90, critical at ≥ 0.95, regardless of pace — so a
///   user pacing "correctly" but nearly out is still told.
///
/// Only the **single most-severe** tier fires per limit. All utilization values are fractions
/// (0…1), matching the parser's normalization — no percent/fraction mixing.
public struct LimitEvaluator: Sendable {
    struct Tier: Sendable {
        let utilization: Double
        let timePct: Double
    }

    static let fiveHourWindow: TimeInterval = 5 * 60 * 60
    static let sevenDayWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Tiers above the 0.70 floor (the sub-floor CLI tiers at 0.25/0.50 are inert under it, so
    /// they're omitted rather than carried dead).
    static let fiveHourTiers = [Tier(utilization: 0.90, timePct: 0.72)]
    static let sevenDayTiers = [Tier(utilization: 0.75, timePct: 0.60)]

    static let floor = 0.70
    static let absoluteWarning = 0.90
    static let absoluteCritical = 0.95

    public init() {}

    /// Warnings for every active limit in the snapshot (at most one per limit). Deliberately
    /// active-only: a notification interrupts, so a window the server marks inactive must not
    /// raise one — even though `bindingLimit` may still *show* it (a glanceable number is lower
    /// stakes than an alert). See `inactiveLimitsAreIgnored`.
    public func warnings(for snapshot: UsageSnapshot, now: Date) -> [UsageWarning] {
        snapshot.limits.filter(\.isActive).compactMap { warning(for: $0, now: now) }
    }

    func warning(for limit: UsageLimit, now: Date) -> UsageWarning? {
        let util = limit.utilization
        var severity: UsageSeverity = .normal
        var threshold = 0.0

        // Absolute near-exhaustion (pace-independent).
        if util >= Self.absoluteCritical {
            severity = .critical
            threshold = Self.absoluteCritical
        } else if util >= Self.absoluteWarning {
            severity = .warning
            threshold = Self.absoluteWarning
        }

        // Time-relative (only when not already critical, and above the floor).
        if severity != .critical, util >= Self.floor, let reset = limit.resetsAt {
            let window = limit.isSession ? Self.fiveHourWindow : Self.sevenDayWindow
            let tiers = limit.isSession ? Self.fiveHourTiers : Self.sevenDayTiers
            let progress = timeProgress(resetsAt: reset, window: window, now: now)
            for tier in tiers where util >= tier.utilization && progress <= tier.timePct {
                if severity == .normal { severity = .warning }
                threshold = max(threshold, tier.utilization)
            }
        }

        guard severity != .normal else { return nil }
        return UsageWarning(
            limitKey: limit.dedupKey,
            limitLabel: limit.shortLabel,
            utilization: util,
            severity: severity,
            threshold: threshold,
            resetsAt: limit.resetsAt
        )
    }

    /// Fraction of the window that has elapsed (0…1): high usage at a low progress is the
    /// "burning too fast" signal the time-relative tiers gate on.
    func timeProgress(resetsAt: Date, window: TimeInterval, now: Date) -> Double {
        let windowStart = resetsAt.addingTimeInterval(-window)
        let elapsed = now.timeIntervalSince(windowStart)
        return (elapsed / window).clamped(to: 0 ... 1)
    }
}

import ClaudeManagerCore
import SwiftUI

/// Visual severity for a usage fraction — escalates as usage climbs, independent of the API's
/// own `severity` (which can read "normal" even when nearly out). Carries both a color and a
/// **non-color** glyph so severity isn't conveyed by color alone (accessibility).
enum UsageDisplaySeverity {
    case normal, warning, critical

    /// From a utilization fraction (0…1): warn at 75%, critical at 90%.
    static func forFraction(_ fraction: Double) -> UsageDisplaySeverity {
        if fraction >= 0.90 { return .critical }
        if fraction >= 0.75 { return .warning }
        return .normal
    }

    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }

    /// A glyph for warning/critical; nil at normal (no clutter when there's nothing to flag).
    var glyph: String? {
        switch self {
        case .normal: nil
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

/// A determinate usage bar: a track with a severity-colored fill. Used in the detail Usage
/// section and (compactly) elsewhere.
struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = 6

    private var severity: UsageDisplaySeverity {
        .forFraction(fraction)
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
        .accessibilityLabel("\(Int((fraction * 100).rounded()))% used")
    }
}

/// A compact ring for a sidebar row: a thin severity-colored arc over a faint track, sized to
/// sit beside `StatusDot`.
struct UsageRing: View {
    let fraction: Double
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.5

    private var severity: UsageDisplaySeverity {
        .forFraction(fraction)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(severity.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// The compact sidebar/row indicator: a binding-limit ring + short label when there's data, a
/// dimmed "needs attention" glyph for login-needed/no-source, or nothing (tracking off / not yet
/// loaded). The tooltip carries the reset countdown and freshness.
struct UsageSidebarIndicator: View {
    let usage: AccountUsage?

    var body: some View {
        // Attention wins over the ring: a `loginNeeded` / `noSource` account can still carry a
        // stale snapshot (so `displayLimit` is non-nil), but a normal-looking ring would hide the
        // action the user must take. The stale numbers stay available in the detail pane.
        if let usage, usage.needsAttention {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(usage.stateNote)
        } else if let usage, let limit = usage.displayLimit {
            HStack(spacing: 4) {
                if let glyph = UsageDisplaySeverity.forFraction(limit.utilization).glyph {
                    Image(systemName: glyph)
                        .font(.caption2)
                        .foregroundStyle(UsageDisplaySeverity.forFraction(limit.utilization).color)
                }
                UsageRing(fraction: limit.utilization)
                Text(UsageFormat.limitSummary(limit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help(tooltip(limit: limit, usage: usage))
        }
    }

    private func tooltip(limit: UsageLimit, usage: AccountUsage) -> String {
        var parts: [String] = []
        if let account = usage.identity.accountLabel { parts.append(account) }
        parts.append("\(limit.shortLabel): \(UsageFormat.percent(limit.utilization)) used")
        if let resets = UsageFormat.resets(limit.resetsAt) { parts.append(resets) }
        if case let .stale(since) = usage.state { parts.append("as of \(UsageFormat.age(since))") }
        return parts.joined(separator: " · ")
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

    /// Whether the account needs a user action (a re-login / authorization) — surfaced even
    /// without a snapshot to show.
    var needsAttention: Bool {
        switch state {
        case .loginNeeded, .noSource: true
        default: false
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

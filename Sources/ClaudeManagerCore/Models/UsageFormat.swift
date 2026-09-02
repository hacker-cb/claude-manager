import Foundation

/// The pure half of the usage vocabulary — string shapes with no locale, no formatter and no main
/// actor, so `UsagePresentation` can build a dated note and `swift test` can assert every one of
/// them.
///
/// The locale-aware half (`resets`, `money`) stays in the app layer as an extension: both hold
/// cached `DateFormatter` / `NumberFormatter` instances behind `@MainActor` because they are called
/// once a minute per row from a `TimelineView`, and rebuilding a formatter per call there would
/// undo the work that made those tickers cheap.
public enum UsageFormat {
    /// `42%` from a fraction.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// `7d 54%` — the one spelling of a limit's compact label, shared by the sidebar row, the
    /// menu-bar status item, and each menu account row, so the three can't drift apart.
    public static func limitSummary(_ limit: UsageLimit) -> String {
        "\(limit.shortLabel) \(percent(limit.utilization))"
    }

    /// `<1m` / `12m` / `2h 52m` / `5d 20h` — how long until something happens, at two
    /// significant units.
    ///
    /// Locale-free on purpose, which is what keeps it in the core beside the rest of the pure
    /// vocabulary: the overview's copy is assembled here and asserted by `swift test`, while the
    /// app layer's `UsageFormat.resets` stays the place an *absolute* time is spelled, since that
    /// one needs a locale and a cached formatter.
    ///
    /// A non-positive interval reads `now` rather than a negative figure — a countdown that has
    /// run out has, and the surfaces that print it gate on the window still being ahead anyway.
    public static func compactDuration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "now" }
        let seconds = Int(interval)
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "3 min ago" / "just now" for a captured-at timestamp.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 3600 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}

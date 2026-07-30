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

    /// "3 min ago" / "just now" for a captured-at timestamp.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 3600 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}

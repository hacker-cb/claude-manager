import Foundation

/// UserDefaults keys for app-level preferences. Per-launcher state lives in the
/// launcher marker (source of truth); these are app UI choices only.
enum PreferenceKeys {
    static let installDirectoryOverride = "installDirectoryOverride"
    static let profilesDirectoryOverride = "profilesDirectoryOverride"
    static let measureSizes = "measureSizes"
    /// JSON-encoded global `BadgeStyle` applied to every launcher icon.
    static let badgeStyle = "badgeStyle"
    /// Whether the `claude://` deep-link broker owns the handler. On by default; unset
    /// reads as on (see `AppModel.init`), an explicit off is honored.
    static let deepLinkBrokerEnabled = "deepLinkBrokerEnabled"

    /// Master switch for plan-usage tracking. On by default (unset → on); an explicit off
    /// stops all polling — no keychain read, network call, or storage.
    static let usageTrackingEnabled = "usageTrackingEnabled"
    /// Background poll interval in minutes; `0` means manual-only (no background polling).
    static let usagePollIntervalMinutes = "usagePollIntervalMinutes"
    /// Whether a running profile is polled on the faster adaptive cadence. On by default.
    static let usageAdaptiveEnabled = "usageAdaptiveEnabled"
    /// Whether limit-approaching reminders are posted. On by default.
    static let usageNotificationsEnabled = "usageNotificationsEnabled"
}

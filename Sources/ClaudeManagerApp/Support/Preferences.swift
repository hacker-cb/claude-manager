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

    /// JSON `[stagedVersion: Date]` — when each staged Claude update was **first seen**.
    /// Persisted because it is the only clock we have on Claude's own 72 h enforcement
    /// timer: that counter lives in the updater's memory, and nothing on disk survives a
    /// re-arm (`ShipItState.plist`'s mtime is rewritten on every retry). Kept to the
    /// currently-staged version, so it can't grow a row per Claude release forever.
    static let stagedUpdateFirstSeen = "stagedUpdateFirstSeen"
    /// Staged versions whose "downloaded, blocked by open profiles" notification has already
    /// been posted. Persisted so the once-per-version promise survives an app restart —
    /// in memory it was renewed on every launch, re-nagging about the same version.
    static let notifiedStagedUpdate = "notifiedStagedUpdate"
    /// Staged versions whose *deadline* warning has been posted — a separate key, because it
    /// is a second, later notification about the same version.
    static let notifiedStagedDeadline = "notifiedStagedDeadline"
}

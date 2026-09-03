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
    /// The Limits page's work mode, as a `WorkMode` raw value. Unset reads as the scoped one:
    /// the per-model week is the scarcer budget, so it is the more useful default to open on.
    static let limitsMode = "limitsMode"

    /// Launcher+version keys whose "restart to update" notification has been posted. Persisted
    /// because it started mattering the moment notifications became visible while the app is
    /// frontmost: in memory, every launch re-notified about every profile still running an
    /// older Claude.
    static let notifiedClaudeUpdates = "notifiedClaudeUpdates"

    /// Whether Claude Manager fetches and installs Claude's updates itself, rather than
    /// leaving that to Claude's own Squirrel updater. Absent means **on**: it is this app's
    /// model of how updating works, not an experiment to be discovered in Settings.
    static let manageClaudeUpdates = "manageClaudeUpdates"

    /// When the release feed was last asked, as epoch seconds. Persisted so relaunching the
    /// app does not turn a four-hourly check into a per-launch one.
    static let lastClaudeUpdateCheck = "lastClaudeUpdateCheck"

    /// When the feed last answered *successfully*, as epoch seconds. Distinct from
    /// `lastClaudeUpdateCheck`, which is stamped when an attempt starts: with Claude's own
    /// updater switched off, a feed that has been failing for weeks means nothing is updating
    /// Claude at all, and only a record of the last success can tell that apart from a
    /// machine that is simply up to date.
    static let lastClaudeUpdateSuccess = "lastClaudeUpdateSuccess"
}

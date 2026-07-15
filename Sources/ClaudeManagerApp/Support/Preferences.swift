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
}

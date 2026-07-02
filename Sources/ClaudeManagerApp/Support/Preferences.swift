import Foundation

/// UserDefaults keys for app-level preferences. Per-launcher state lives in the
/// launcher marker (source of truth); these are app UI choices only.
enum PreferenceKeys {
    static let installDirectoryOverride = "installDirectoryOverride"
    static let profilesDirectoryOverride = "profilesDirectoryOverride"
    static let measureSizes = "measureSizes"
}

import Foundation

/// Where launchers are installed and where new profile data dirs default to.
public struct ProfileStoreConfiguration: Sendable, Equatable {
    /// Directory the launcher `.app` bundles live in (defaults to the real app's
    /// own directory, so launchers sit next to Claude.app).
    public var installDirectory: URL
    /// Parent directory for auto-created `--user-data-dir`s.
    public var defaultProfilesDirectory: URL
    /// Global badge look applied to every launcher icon this store builds.
    public var badgeStyle: BadgeStyle
    /// MDM managed-preferences plists whose presence overrides our local config tier.
    /// Injectable so tests stay hermetic (never read the host's real machine state).
    public var managedPreferencesURLs: [URL]

    public init(
        installDirectory: URL,
        defaultProfilesDirectory: URL,
        badgeStyle: BadgeStyle = .default,
        managedPreferencesURLs: [URL] = CoreConstants.claudeManagedPreferencesPaths
            .map { URL(fileURLWithPath: $0) }
    ) {
        self.installDirectory = installDirectory
        self.defaultProfilesDirectory = defaultProfilesDirectory
        self.badgeStyle = badgeStyle
        self.managedPreferencesURLs = managedPreferencesURLs
    }

    public static func makeDefault(
        realClaude: RealClaude,
        fileManager: FileManager = .default
    ) -> ProfileStoreConfiguration {
        ProfileStoreConfiguration(
            installDirectory: realClaude.installDirectory,
            defaultProfilesDirectory: MetadataStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("Profiles", isDirectory: true)
        )
    }
}

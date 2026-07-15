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
    /// The default account's Electron user-data dir (`~/Library/Application
    /// Support/Claude`). Its `-3p` sibling is where the deep-link broker writes
    /// `disableDeepLinkRegistration`. Injectable so tests never touch the real default.
    public var defaultAccountUserDataPath: String
    /// Whether the `claude://` broker owns the handler. When on, clones *and* the
    /// default account suppress their own deep-link registration; when off (the safe
    /// default) the default account is left untouched and a prior overlay is restored.
    public var deepLinkBrokerEnabled: Bool
    /// ShipIt state file that names a staged Claude update (`ShipItState.plist`).
    /// Injectable so tests never read the host's real ShipIt cache.
    public var shipItStatePath: String

    public init(
        installDirectory: URL,
        defaultProfilesDirectory: URL,
        badgeStyle: BadgeStyle = .default,
        managedPreferencesURLs: [URL] = CoreConstants.claudeManagedPreferencesPaths
            .map { URL(fileURLWithPath: $0) },
        defaultAccountUserDataPath: String = ProfileStoreConfiguration.systemDefaultAccountUserDataPath,
        deepLinkBrokerEnabled: Bool = false,
        shipItStatePath: String = CoreConstants.shipItStatePath(
            forBundleID: CoreConstants.realClaudeBundleIDs[0]
        )
    ) {
        self.installDirectory = installDirectory
        self.defaultProfilesDirectory = defaultProfilesDirectory
        self.badgeStyle = badgeStyle
        self.managedPreferencesURLs = managedPreferencesURLs
        self.defaultAccountUserDataPath = defaultAccountUserDataPath
        self.deepLinkBrokerEnabled = deepLinkBrokerEnabled
        self.shipItStatePath = shipItStatePath
    }

    /// `~/Library/Application Support/Claude` — the real default account's user-data dir.
    public static var systemDefaultAccountUserDataPath: String {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(CoreConstants.defaultAccountUserDataDirName).path
    }

    public static func makeDefault(
        realClaude: RealClaude,
        fileManager: FileManager = .default
    ) -> ProfileStoreConfiguration {
        // Derive the ShipIt state path from the real app's actual bundle id, so a
        // legacy-id install (`com.anthropic.claudeapp`) is detected too.
        let bundleID = realClaude.bundleIdentifier(fileManager: fileManager)
            ?? CoreConstants.realClaudeBundleIDs[0]
        return ProfileStoreConfiguration(
            installDirectory: realClaude.installDirectory,
            defaultProfilesDirectory: MetadataStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("Profiles", isDirectory: true),
            shipItStatePath: CoreConstants.shipItStatePath(forBundleID: bundleID)
        )
    }
}

import Foundation

/// Compile-time constants shared across the core. Kept in one place so the
/// launcher marker key, bundle-id scheme, and absolute tool paths have a single
/// source of truth.
public enum CoreConstants {
    /// Info.plist dictionary key that marks a bundle as a launcher managed by this
    /// tool. The presence of this key — and nothing else — is what makes a `.app`
    /// "ours" when scanning the install directory (the marker is the source of truth).
    public static let markerKey = "ClaudeManagerLauncher"

    /// Version of the generated launcher *wrapper* — the bash script rendered by
    /// `LauncherScript.render` plus the keys written by `LauncherBundle.writeInfoPlist`.
    /// It is stamped into every launcher's marker at build time. **Bump it whenever
    /// that generated output changes**: a launcher whose stored version is lower than
    /// this reads back as stale (`Discovered.isStale` / `ManagedProfile.needsRebuild`),
    /// and the app offers a rebuild. This is the wrapper format version, NOT the app's
    /// `MARKETING_VERSION`.
    ///
    /// History: 1 = MVP. 2 = adds `LSArchitecturePriority` so profiles run native
    /// (arm64) instead of translated under Rosetta.
    public static let currentWrapperVersion = 2

    /// The single source of the staleness rule: whether a launcher stamped with
    /// `version` predates `currentWrapperVersion` and should be offered a rebuild.
    /// Both `Discovered.isStale` and `ManagedProfile.needsRebuild` defer to this so
    /// the Doctor warning and the UI rebuild affordance can never disagree.
    public static func wrapperVersionIsStale(_ version: Int) -> Bool {
        version < currentWrapperVersion
    }

    /// `~/Library/Application Support/<name>` folder for GUI metadata and the
    /// default location of new profile data directories.
    public static let appSupportDirectoryName = "Claude Manager"

    /// Reverse-DNS prefix for auto-generated launcher bundle identifiers.
    public static let defaultBundleIDPrefix = "io.github.hacker-cb.claude-manager.launcher"

    /// Bundle identifiers the real Claude Desktop app has shipped under, most
    /// current first. Used to locate the untouched app to wrap.
    public static let realClaudeBundleIDs = [
        "com.anthropic.claudefordesktop",
        "com.anthropic.claudeapp"
    ]

    /// Path fallback when LaunchServices cannot resolve the app by bundle id.
    public static let defaultRealClaudePath = "/Applications/Claude.app"

    /// Executable name inside the real app bundle (`Contents/MacOS/<name>`).
    public static let defaultRealExecutableName = "Claude"

    /// Icon resource inside the real app bundle used as the badge base.
    public static let defaultRealIconFileName = "electron.icns"

    // MARK: - Absolute tool paths (avoid $PATH surprises in a GUI process)

    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    public static let iconutilPath = "/usr/bin/iconutil"
    public static let openPath = "/usr/bin/open"
    public static let pgrepPath = "/usr/bin/pgrep"
    public static let psPath = "/bin/ps"
    public static let touchPath = "/usr/bin/touch"
    public static let killallPath = "/usr/bin/killall"
    public static let duPath = "/usr/bin/du"
}

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
    /// `LauncherScript.render`, the keys written by `LauncherBundle.writeInfoPlist`, and
    /// the rest of the bundle `LauncherBundle.build` produces. It is stamped into every
    /// launcher's marker at build time. **Bump it whenever that generated output
    /// changes**: a launcher whose stored version is lower than this reads back as stale
    /// (`Discovered.isStale` / `ManagedProfile.needsRebuild`), and the app offers a
    /// rebuild. This is the wrapper format version, NOT the app's `MARKETING_VERSION`.
    ///
    /// History: 1 = MVP. 2 = adds `LSArchitecturePriority` so profiles run native
    /// (arm64) instead of translated under Rosetta. 3 = the bundle is ad-hoc signed;
    /// without a signature macOS refuses to execute a newly built launcher at all, so
    /// every unsigned bundle must be flagged for rebuild.
    public static let currentWrapperVersion = 3

    /// The single source of the staleness rule: whether a launcher stamped with
    /// `version` predates `currentWrapperVersion` and should be offered a rebuild.
    /// Both `Discovered.isStale` and `ManagedProfile.needsRebuild` defer to this so
    /// the Doctor warning and the UI rebuild affordance can never disagree.
    public static func wrapperVersionIsStale(_ version: Int) -> Bool {
        version < currentWrapperVersion
    }

    /// First wrapper version whose launchers macOS will actually execute: v3 is where
    /// the bundle became ad-hoc signed, and an unsigned launcher is refused by
    /// AppleSystemPolicy — it appears in the Dock and is killed. Everything below is
    /// therefore **dead**, not merely dated.
    public static let minimumRunnableWrapperVersion = 3

    /// Whether a launcher stamped with `version` is one macOS refuses to launch, so a
    /// rebuild is the only way to make it work again. Kept apart from
    /// `wrapperVersionIsStale` on purpose: staleness means "misses the latest
    /// improvements" and the app words it as optional, while this means "does not run"
    /// and is surfaced as an error.
    public static func wrapperVersionIsUnrunnable(_ version: Int) -> Bool {
        version < minimumRunnableWrapperVersion
    }

    /// The `MARKETING_VERSION` placeholder a local/dev build carries (see project.yml).
    /// A real release injects a semver from the git tag, so this value distinguishes a
    /// shipped build from a local one.
    public static let devMarketingVersion = "0.0.0"

    /// Whether a build carrying `marketingVersion` is a distributed release rather than a
    /// local/dev build still on the placeholder. Used to keep Sparkle's updater dormant in
    /// dev builds, where it would otherwise see every published release as an upgrade and
    /// nag the developer to overwrite their own build. Keyed on the marketing version, NOT
    /// `CFBundleVersion`: the build number is the CI run number, which is legitimately `1`
    /// on a repo's first release run and would collide with the dev placeholder.
    public static func isDistributionBuild(marketingVersion: String) -> Bool {
        marketingVersion != devMarketingVersion
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

    // MARK: - Claude managed-config overlay

    /// MDM-delivered managed-preferences plists for the real Claude app — one per
    /// bundle id we may wrap (current + legacy). When any exists, Claude's *managed*
    /// config tier overrides the per-userData *local* tier we write into, so our
    /// overlay would be ignored — the writer skips it and `Doctor` surfaces a note.
    /// Derived from `realClaudeBundleIDs` so a legacy-id install is covered too.
    public static let claudeManagedPreferencesPaths = realClaudeBundleIDs.map {
        "/Library/Managed Preferences/\($0).plist"
    }

    /// Claude Desktop version whose managed-config resolver and key schema this
    /// overlay was reverse-engineered and verified against. The flat enterprise-policy
    /// keys (e.g. `disableAutoUpdates`) and the `<userData>-3p/configLibrary`
    /// local-tier path are pinned to this build; a newer Claude may reshape them, so
    /// all overlay parsing is defensive (nil/skip on failure) rather than trusted.
    public static let claudeManagedConfigValidatedVersion = "1.20186.1"

    /// The default profile's Electron user-data dir name under Application Support
    /// (`~/Library/Application Support/Claude`). Its managed-config local tier is the
    /// `-3p` sibling; the broker keeps it overlay-free (the default's `claude://` handler
    /// is held by the guard, not a written key) and only cleans up a stray key there.
    public static let defaultProfileUserDataDirName = "Claude"

    /// The custom URL scheme Claude Desktop owns and the broker takes over.
    public static let claudeURLScheme = "claude"

    /// ShipIt (Squirrel.Mac) per-bundle state file — `ShipItState.plist` under Caches,
    /// which is **JSON** despite the extension. When a job is armed it names the staged
    /// `updateBundleURL`; reading it is how we detect a staged-but-unapplied update that
    /// running clones are blocking. Keyed by the app's bundle id.
    public static func shipItStatePath(
        forBundleID bundleID: String,
        home: String = NSHomeDirectory()
    ) -> String {
        "\(home)/Library/Caches/\(bundleID).ShipIt/ShipItState.plist"
    }

    // MARK: - Plan-usage statistics

    /// On-disk schema version for the usage-history SQLite store. **Bump when the stored
    /// `UsageSnapshot` shape or the DB schema changes** — the store drops-and-recreates on
    /// mismatch (early-stage: history is a cache, not a contract). Mirrors the intent of
    /// `currentWrapperVersion`, but for the stats DB rather than the launcher format.
    public static let usageSchemaVersion = 3

    /// Base URL for the OAuth usage/profile endpoints. The whole core had no networking
    /// before plan-usage stats; this is the single place that host is named.
    public static let usageAPIBaseURL = "https://api.anthropic.com"

    /// `/api/oauth/usage` — per-account plan-usage limits (session / weekly / scoped / extra).
    public static let usageAPIUsagePath = "/api/oauth/usage"

    /// `/api/oauth/profile` — account identity (email, uuid, subscription); cached long.
    public static let usageAPIProfilePath = "/api/oauth/profile"

    /// Beta header value required by the OAuth usage/profile endpoints (proven sufficient
    /// on its own — `anthropic-version` is not required for these calls).
    public static let oauthBetaHeaderValue = "oauth-2025-04-20"

    // MARK: - Desktop safeStorage (Electron) token decryption

    /// Keychain generic-password item that holds the Electron safeStorage AES *password*
    /// — one item shared by every Claude Desktop clone (they share bundle id
    /// `com.anthropic.claudefordesktop`). The per-account OAuth token itself lives inside
    /// each account's `config.json`, encrypted with the key derived from this password.
    public static let safeStorageKeychainService = "Claude Safe Storage"
    public static let safeStorageKeychainAccount = "Claude"

    /// PBKDF2 parameters Electron's macOS safeStorage uses to turn the keychain password
    /// into the AES-128 key (same scheme as Chrome "Safe Storage"): HMAC-SHA1, salt
    /// `saltysalt`, 1003 rounds, 16-byte key. AES-128-CBC with a 16-space IV; blobs are
    /// prefixed `v10`. Reverse-engineered and verified against the shipping Desktop build.
    public static let safeStoragePBKDFSalt = "saltysalt"
    public static let safeStoragePBKDFRounds = 1003
    public static let safeStorageKeyLength = 16
    public static let safeStorageBlobPrefix = "v10"

    /// `config.json` keys inside a Desktop account's user-data dir. `tokenCacheV2` is the
    /// current encrypted token cache; `tokenCache` is the legacy fallback.
    /// `lastKnownAccountUuid` is a *hint* for the account UUID (the token is the truth).
    public static let desktopTokenCacheKeyV2 = "oauth:tokenCacheV2"
    public static let desktopTokenCacheKeyV1 = "oauth:tokenCache"
    public static let desktopLastAccountKey = "lastKnownAccountUuid"

    /// The decrypted `tokenCacheV2` is a JSON **map** keyed
    /// `"<clientId>:<orgUuid>:<audience>:<space-separated scopes>"`. The audience
    /// (`https://api.anthropic.com`) itself contains colons, so the key is NOT safely
    /// split on `:` — match by `hasPrefix(clientID)` + `contains(inferenceScope)` instead,
    /// and read the org UUID as the 36 chars after `"<clientID>:"`. Each value carries
    /// `token` (the bearer — NOT `accessToken`), `refreshToken`, `expiresAt` (**epoch
    /// milliseconds**), `subscriptionType`, `rateLimitTier`.
    public static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let oauthInferenceScope = "user:inference"
    public static let oauthProfileScope = "user:profile"

    // MARK: - Absolute tool paths (avoid $PATH surprises in a GUI process)

    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    public static let iconutilPath = "/usr/bin/iconutil"
    /// Base-system tool (not an Xcode Command Line Tools shim) — used to ad-hoc sign
    /// every launcher bundle, without which macOS refuses to run it.
    public static let codesignPath = "/usr/bin/codesign"
    public static let openPath = "/usr/bin/open"
    public static let pgrepPath = "/usr/bin/pgrep"
    public static let psPath = "/bin/ps"
    public static let touchPath = "/usr/bin/touch"
    public static let killallPath = "/usr/bin/killall"
    public static let duPath = "/usr/bin/du"
}

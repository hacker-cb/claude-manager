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
    /// every unsigned bundle must be flagged for rebuild. 4 = the badge resource is
    /// content-addressed (`Badge-<sha256[:16]>.icns`, see `LauncherBundle.iconFileName`);
    /// a launcher still on the fixed `Badge.icns` keeps hitting the stale IconServices
    /// entry after an edit, so it is offered a rebuild.
    public static let currentWrapperVersion = 4

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

    /// ShipIt's own `stderr` log, which sits beside the state file in the same per-bundle
    /// cache — the only place the *reason* an install failed is ever written (the state
    /// file records the job, never its outcome).
    ///
    /// Derived from the state path rather than taking a second injectable path: Squirrel
    /// writes both into one directory it names itself, so a test that redirects the state
    /// file redirects this too, and the two can never drift onto different bundles.
    public static func shipItStderrPath(forStatePath statePath: String) -> String {
        URL(fileURLWithPath: statePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ShipIt_stderr.log")
            .path
    }

    /// How long Claude's installer has to be running before Doctor calls it stuck.
    ///
    /// A swap is 3–5 s, and the worst measured under disk contention was 57 s. Ten minutes
    /// is therefore two orders of magnitude past "installing" and can only mean ShipIt is
    /// waiting for every Claude instance to quit — which it does **indefinitely and
    /// silently**, the failure mode that ran unnoticed for nine days.
    public static let shipItStuckSeconds: TimeInterval = 600

    // MARK: - Plan-usage statistics

    /// On-disk schema version for the usage-history SQLite store. **Bump when the stored
    /// `UsageSnapshot` shape or the DB schema changes** — the store drops-and-recreates on
    /// mismatch (early-stage: history is a cache, not a contract). Mirrors the intent of
    /// `currentWrapperVersion`, but for the stats DB rather than the launcher format.
    public static let usageSchemaVersion = 5

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

    /// Keychain generic-password **service** that holds the Electron safeStorage AES *password*
    /// — one secret shared by every Claude Desktop clone (they share bundle id
    /// `com.anthropic.claudefordesktop`). The per-account OAuth token itself lives inside
    /// each account's `config.json`, encrypted with the key derived from this password.
    ///
    /// The **account** is deliberately *not* a constant: Chromium's `os_crypt` migration to the
    /// async provider stores the same password under a second account (`keychain_password_mac.mm`
    /// writes `"Claude"` = the app name; `os_crypt/async/.../keychain_key_provider.mm` writes
    /// `"Claude Key"` = app name + `" Key"`), and which of the two a given machine carries depends
    /// on its Claude version and migration state — one, the other, or both. The `service` is the
    /// only stable anchor across that churn, so `SafeStorageKeyStore` enumerates every item under
    /// it (account-agnostic) and keeps whichever password actually decrypts the token cache,
    /// instead of guessing an account name that a future provider rename would break.
    public static let safeStorageKeychainService = "Claude Safe Storage"

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
    public static let desktopTokenCacheKeyV2 = "oauth:tokenCacheV2"
    public static let desktopTokenCacheKeyV1 = "oauth:tokenCache"

    /// The account UUID Desktop records for the profile, in **plaintext**, beside the encrypted
    /// caches above — rewritten on every login and left in place on logout.
    ///
    /// Read for **display only**, and the boundary is absolute: where usage is *filed* still comes
    /// from the token alone — its fingerprint locally, `/oauth/profile` authoritatively. This hint
    /// is consulted only for a binding that produced no usable token, which is the branch that
    /// writes no sample, no throttle row and no ledger entry, so a hint lagging a re-login can
    /// misname a row for one poll and can never misfile a byte.
    ///
    /// That boundary is what makes it safe, because the hint on its own is not: it lags exactly
    /// when it matters least to us and most to a merge — which is why `AccountResolver` still
    /// refuses to group on it, and why nothing here may ever become a storage key.
    public static let desktopAccountHintKey = "lastKnownAccountUuid"

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

    // MARK: - Claude Desktop releases

    /// Anthropic's desktop release API: the newest published build and its `.zip`, as
    /// `{"version": "1.37937.1", "url": "https://…/Claude-<id>.zip"}`.
    ///
    /// `universal` matches how Claude Desktop ships on macOS — the same slice its own
    /// updater requests — so the download is the very bundle Anthropic distributes rather
    /// than a per-architecture variant this app would have to choose between.
    ///
    /// The API is not publicly documented, which is why every field is parsed defensively
    /// and ``claudeReleaseFeedValidatedVersion`` records what it was last checked against.
    public static let latestReleaseFeedURL = URL(
        string: "https://api.anthropic.com/api/desktop/darwin/universal/zip/latest"
    )! // swiftlint:disable:this force_unwrapping

    /// Release whose feed contract — the two-field payload above — was verified by hand.
    /// A `LiveUpdateFeedTests` case re-checks it against the real endpoint on demand, so a
    /// reshaped payload surfaces as a failing opt-in test rather than a silent no-op.
    public static let claudeReleaseFeedValidatedVersion = "1.37937.1"

    /// Anthropic's Apple Developer team identifier, as it appears in Claude's signature
    /// (`TeamIdentifier=Q6L2SF6YDW`).
    public static let anthropicTeamIdentifier = "Q6L2SF6YDW"

    /// The requirement a downloaded bundle must satisfy to be Anthropic's build.
    ///
    /// This is the form Apple's own tooling prints for a Developer ID application, not a
    /// hand-rolled shorthand: `anchor apple generic` pins the chain to Apple's roots, the
    /// two marker OIDs pin it to the **Developer ID** CA and leaf specifically, and the
    /// leaf's OU is the team. Together they say "Apple issued this, as a Developer ID
    /// application, to Anthropic".
    ///
    /// The marker OIDs are not decoration. Without them the requirement admits any
    /// Apple-anchored certificate whose OU happens to match — a Mac Developer or
    /// installer-signing certificate, for instance. `spctl` would normally catch that, but
    /// `spctl --assess` answers according to the machine's Gatekeeper state, and on a system
    /// where assessments are disabled it stops asserting anything at all. This requirement
    /// is then the only line left, so it is the one that must be exact.
    ///
    /// Handed to `codesign -R`, so it is evaluated by the same code that validates the
    /// signature rather than by parsing `codesign -dv` output, where a locale or a format
    /// change is a silent misread. A malformed requirement fails closed: `codesign` exits
    /// non-zero rather than skipping the check.
    public static let anthropicDesignatedRequirement = """
    =anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = "\(anthropicTeamIdentifier)"
    """

    /// The bundle name inside a release archive, and the name it is installed under.
    public static let claudeAppName = "Claude.app"

    /// Names a macOS-built zip may carry beside its payload. Enumerated deliberately: a
    /// blanket "ignore hidden entries" rule would let an archive hide arbitrary content from
    /// a check whose claim is that it unpacked to exactly one bundle.
    public static let archiveMetadataNames: Set<String> = ["__MACOSX", ".DS_Store"]

    /// Where downloaded builds and the bundle unpacked from them live.
    ///
    /// Under `Caches` because it is all reproducible — losing it costs a re-download, not
    /// data — and, more importantly, because it is on the same volume as `/Applications`:
    /// the install swaps the unpacked bundle in by rename, which is atomic only within a
    /// volume. A staging area under `/tmp` would satisfy neither.
    public static func updateCacheDirectory(
        forBundleID bundleID: String,
        home: String = NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: "\(home)/Library/Caches/\(bundleID)/ClaudeUpdates")
    }

    /// Subdirectory of the cache holding the unpacked, verified bundle.
    public static let updateStagingDirectoryName = "staged"

    /// Timeout for the feed request. Short on purpose: this runs on a background check
    /// whose failure is simply "ask again later", so waiting out a hung connection buys
    /// nothing.
    public static let updateFeedTimeout: TimeInterval = 20

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
    /// Apple's archive tool. Used instead of `unzip` to unpack a signed bundle: it preserves
    /// extended attributes and symlinks, which a signature covers and `unzip` need not keep.
    public static let dittoPath = "/usr/bin/ditto"
    /// Gatekeeper assessment — the notarization ticket check.
    public static let spctlPath = "/usr/sbin/spctl"
}

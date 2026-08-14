import Darwin
import Foundation

/// Parameters for creating a launcher; `nil` fields fall back to sensible defaults.
public struct AddProfileRequest: Sendable {
    public var name: String
    public var label: String?
    public var color: BadgeColor?
    public var displayName: String?
    public var bundleID: String?
    public var profilePath: String?
    public var force: Bool

    public init(
        name: String,
        label: String? = nil,
        color: BadgeColor? = nil,
        displayName: String? = nil,
        bundleID: String? = nil,
        profilePath: String? = nil,
        force: Bool = false
    ) {
        self.name = name
        self.label = label
        self.color = color
        self.displayName = displayName
        self.bundleID = bundleID
        self.profilePath = profilePath
        self.force = force
    }
}

public struct AddResult: Sendable {
    public let profile: Profile
    /// True when the profile dir already held data (likely still signed in).
    public let reusedProfileData: Bool
    /// True when this write changed the launcher's icon at a path whose Dock tile could
    /// already be cached (a forced rebuild, or a trashed same-named twin) — so a pinned
    /// tile keeps the old icon until the Dock is refreshed, and the app may offer an
    /// opt-in "Refresh Dock now". False for a brand-new bundle (nothing cached at a fresh
    /// path), or when the icon's *presentation* is unchanged — both the recorded
    /// `CFBundleIconFile` and the bytes behind it. A pre-v4 launcher migrating onto the
    /// content-addressed name counts as changed on the name alone, even where its bytes
    /// already match, because that is exactly the bundle whose drawn tile is stale.
    public let dockRefreshPending: Bool
}

public struct UpdateResult: Sendable {
    public let profile: Profile
    /// See `AddResult.dockRefreshPending`: true when the edit changed the icon at an
    /// in-place path (or a rename onto a trashed twin) whose Dock tile could be stale.
    public let dockRefreshPending: Bool
    /// Set when the edit was applied under a live instance — see `LiveRewrite`.
    public let liveRewrite: LiveRewrite?
}

public enum StopOutcome: Sendable, Equatable {
    case notRunning
    case stopped
    case stillRunning(pid: Int32)
}

/// The façade the app talks to: scan, add, remove, open, stop, edit, rebuild
/// launchers, and run diagnostics. Composed of small injectable services so the whole
/// thing is testable against temp directories and a mock `CommandRunner`.
public struct ProfileStore {
    public let realClaude: RealClaude
    public let configuration: ProfileStoreConfiguration

    let runner: CommandRunner
    let fileManager: FileManager
    let bundle: LauncherBundle
    let codeSigner: CodeSigner
    let processProbe: ProcessProbe
    let iconCache: IconCache
    let iconPipeline: IconPipeline
    let signalSender: @Sendable (Int32, Int32) -> Int32

    public init(
        realClaude: RealClaude,
        configuration: ProfileStoreConfiguration,
        runner: CommandRunner = SystemCommandRunner(),
        fileManager: FileManager = .default,
        signalSender: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }
    ) {
        self.realClaude = realClaude
        self.configuration = configuration
        self.runner = runner
        self.fileManager = fileManager
        self.signalSender = signalSender
        bundle = LauncherBundle(fileManager: fileManager, runner: runner)
        codeSigner = CodeSigner(runner: runner)
        processProbe = ProcessProbe(runner: runner)
        iconCache = IconCache(runner: runner)
        iconPipeline = IconPipeline(packer: IcnsPacker(runner: runner, fileManager: fileManager))
    }

    /// The profile as the launcher installed at its path actually describes itself — or a
    /// throw, where that launcher is someone else's or is not ours at all.
    ///
    /// Every write goes through this, because the type system stops short of it: `ProfileEdits`
    /// carries no identity and `Profile`'s fields are `let`, but `draft` is public and mints a
    /// `Profile` with any `displayName` and any `profilePath`, so one can still be shaped to sit
    /// on an installed bundle. Building from that repoints the bundle and abandons the login
    /// and chat history in the directory it had.
    ///
    /// Three cases, and the middle one is the dangerous one:
    /// - **Nothing at the path.** Allowed: `update` may rebuild a bundle the user deleted from
    ///   under it, and `rebuild` reports the absence with its own error.
    /// - **Something at the path with no marker.** Refused. `readMarker` returns `nil` here
    ///   too, and reading that as "nothing installed" is how a foreign bundle gets built over:
    ///   `build` ends in `replaceItemAt`, which deletes what it replaces, and the default
    ///   install directory is the real Claude.app's own — a profile drafted with the display
    ///   name "Claude" would destroy the user's Claude installation.
    /// - **One of ours.** It must be *this* profile — same name, same directory — and the
    ///   returned profile adopts the marker's spelling of that directory. `runningPID` greps
    ///   for the literal path, so writing back a different spelling of the same directory
    ///   would hide a live instance from `stop`, `list` and `remove`.
    ///
    ///   Everything else the launcher records — display name, label, colour, bundle id — is
    ///   adopted the same way, which is what makes `rebuild`'s "regenerates from the bundle's
    ///   own marker" true rather than nearly true. `build` writes all of it from the profile it
    ///   is handed, so a `Profile` captured before an edit — a row's context menu, a detail
    ///   pane, any value held across the refresh — would have `rebuild` write those older values
    ///   back, undoing as much of the edit as that value is stale. The bundle path is settled
    ///   from the volume's spelling of it for the same reason: after a rename in place the
    ///   pre-rename path still opens the same file, so the rebuild would rename the launcher
    ///   *back* and rewrite `CFBundleName` with it, leaving a running instance showing the old
    ///   name and no restart nudge, since a rebuild reports none. Before an in-place rename was
    ///   possible none of this was reachable: a rename retired the old bundle, so a stale path
    ///   resolved to nothing and `rebuild` threw `launcherNotFound`.
    ///
    /// This takes nothing away from `update`: an edit's new values arrive in `ProfileEdits` and
    /// are applied to the profile this returns, never read back from it.
    func profileMatchingItsLauncher(_ profile: Profile) throws -> Profile {
        guard let installed = bundle.readMarker(at: profile.appURL) else {
            guard !fileManager.fileExists(atPath: profile.appPath) else {
                throw ClaudeManagerError.markerMissing(path: profile.appPath)
            }
            // Nothing installed vouches for this profile, so the checks `add` performs on a
            // fresh one apply here too — a write down this branch *creates* a launcher.
            // `update` skips the name check when a marker has vouched for the name (that is
            // how a hand-edited invalid one stays editable), which is exactly why it cannot
            // be skipped when nothing has: `draft` derives the data directory from the name,
            // so `../bad` would put it outside the profiles directory.
            guard Profile.isValidName(profile.name) else {
                throw ClaudeManagerError.invalidProfileName(profile.name)
            }
            if let pid = runningPID(for: profile) {
                throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
            }
            return profile
        }
        guard installed.marker.name == profile.name,
              PathUtils.sameDirectory(installed.marker.profile, profile.profilePath)
        else {
            throw ClaudeManagerError.launcherBelongsToAnotherProfile(
                appPath: profile.appPath,
                installedName: installed.marker.name,
                installedPath: installed.marker.profile
            )
        }
        // Everything the launcher itself records, taken from the launcher — the whole profile
        // rather than a field or two of it, since any of them stale reverts that much of an
        // edit. Only the bundle path is rebuilt, from the volume's own spelling of it.
        //
        // A spelling that cannot be read falls back to the caller's, rather than refusing. This
        // function gates `remove` as well as the writes, and `remove` needs no spelling at all —
        // it trashes a path that opens the same bundle either way. Refusing here would leave a
        // profile that can be neither edited, rebuilt *nor* deleted, over an attribute none of
        // those three needs, with a message about a rename nobody asked for. The fallback is
        // safe in the way that matters: a stale spelling only reverts a rename if something
        // renames the launcher to it, and the one step that does — `alignInstalledSpelling` —
        // cannot read the name either, so it does nothing and `replaceItemAt` keeps the name
        // already on disk.
        let installedPath = PathUtils.spellingOnDisk(profile.appPath) ?? profile.appPath
        let onDisk = installed.profile
        return Profile(
            name: onDisk.name,
            displayName: onDisk.displayName,
            label: onDisk.label,
            color: onDisk.color,
            profilePath: onDisk.profilePath,
            bundleID: onDisk.bundleID,
            appPath: installedPath
        )
    }

    /// Locate the real app and build a store with default locations.
    public static func makeDefault(
        runner: CommandRunner = SystemCommandRunner(),
        fileManager: FileManager = .default,
        installDirectoryOverride: URL? = nil,
        defaultProfilesDirectoryOverride: URL? = nil
    ) throws -> ProfileStore {
        let real = try RealClaudeLocator().locate()
        var config = ProfileStoreConfiguration.makeDefault(realClaude: real, fileManager: fileManager)
        if let installDirectoryOverride { config.installDirectory = installDirectoryOverride }
        if let defaultProfilesDirectoryOverride {
            config.defaultProfilesDirectory = defaultProfilesDirectoryOverride
        }
        return ProfileStore(realClaude: real, configuration: config, runner: runner, fileManager: fileManager)
    }

    // MARK: - Read

    /// The launcher list *and* the default-profile status from a single `ps` sweep, so a
    /// refresh pays for one process scan instead of two (`list` and the default-pid probe
    /// each swept the table independently). The one read the app's `refresh` uses.
    public func snapshot(measuringSizes: Bool = false) -> StoreSnapshot {
        let mains = processProbe.allClaudeMains()
        return StoreSnapshot(
            profiles: list(measuringSizes: measuringSizes, mains: mains),
            primaryProfile: PrimaryProfileStatus(pid: defaultPID(in: mains))
        )
    }

    /// All managed launchers with live running state (and optional disk usage). Also
    /// stamps each with the Claude version it's running vs the one on disk, so a
    /// launcher left on an older build surfaces as "restart to update".
    public func list(measuringSizes: Bool = false) -> [ManagedProfile] {
        list(measuringSizes: measuringSizes, mains: processProbe.allClaudeMains())
    }

    /// `list`, but reusing an already-fetched process sweep for the running-version map — so
    /// `snapshot` can share one `ps` across the launcher list and the default-profile status.
    /// `private`: an implementation detail shared only by `snapshot` and the no-arg `list`.
    private func list(measuringSizes: Bool, mains: [ClaudeInstance]) -> [ManagedProfile] {
        let availableVersion = realClaude.version(fileManager: fileManager)
        let runningVersions = processProbe.runningVersionsByProfilePath(from: mains)
        return bundle.scan(installDirectory: configuration.installDirectory).launchers.map { discovered in
            let profile = discovered.profile
            let pid = runningPID(for: profile)
            let size = measuringSizes ? diskSize(of: profile.profilePath) : nil
            return ManagedProfile(
                profile: profile,
                pid: pid,
                diskSize: size,
                wrapperVersion: discovered.wrapperVersion,
                runningClaudeVersion: pid != nil ? runningVersions[profile.profilePath] : nil,
                availableClaudeVersion: availableVersion
            )
        }
    }

    /// The staged-but-unapplied Claude update (if any) — a ShipIt job armed with a newer
    /// bundle that open instances are blocking. Surfaced by the app apart from the launcher
    /// list (a global banner / menu item), and re-probed at apply time.
    public func stagedUpdate() -> StagedUpdate? {
        StagedUpdateProbe(
            realClaude: realClaude,
            shipItStatePath: configuration.shipItStatePath,
            fileManager: fileManager
        ).probe()
    }

    /// The full defaults a new profile named `name` would get — drives the editor
    /// preview before anything is written.
    public func draft(
        name: String,
        label: String? = nil,
        color: BadgeColor? = nil,
        displayName: String? = nil,
        bundleID: String? = nil,
        profilePath: String? = nil
    ) -> Profile {
        let display = displayName?.isEmpty == false ? displayName! : Profile.defaultDisplayName(for: name)
        let app = configuration.installDirectory.appendingPathComponent("\(display).app")
        let resolvedProfile: String = if let profilePath, !profilePath.isEmpty {
            // Normalize to absolute so a relative path never resolves against the
            // process working directory (unpredictable for a GUI app).
            PathUtils.absolutePath(profilePath, relativeTo: configuration.defaultProfilesDirectory)
        } else {
            configuration.defaultProfilesDirectory.appendingPathComponent(name.lowercased()).path
        }
        // Store the label as-is; casing is applied at render by BadgeStyle.drawnLabel.
        let resolvedLabel = label?.isEmpty == false
            ? label!
            : Profile.defaultLabel(for: name, maxLength: configuration.badgeStyle.maxLabelLength)
        return Profile(
            name: name,
            displayName: display,
            label: resolvedLabel,
            color: color ?? .named("blue"),
            profilePath: resolvedProfile,
            bundleID: bundleID?.isEmpty == false ? bundleID! : Profile.defaultBundleID(for: name),
            appPath: app.path
        )
    }

    // MARK: - Mutations

    /// Create a launcher and its profile dir.
    @discardableResult
    public func add(_ request: AddProfileRequest) throws -> AddResult {
        try ensureRealBinaryPresent()
        guard Profile.isValidName(request.name) else {
            throw ClaudeManagerError.invalidProfileName(request.name)
        }

        var profile = draft(
            name: request.name,
            label: request.label,
            color: request.color,
            displayName: request.displayName,
            bundleID: request.bundleID,
            profilePath: request.profilePath
        )
        // The display name becomes the .app filename — reject anything that would
        // let the bundle path escape the install directory.
        guard Profile.isValidDisplayName(profile.displayName) else {
            throw ClaudeManagerError.invalidDisplayName(profile.displayName)
        }
        guard Profile.isValidBundleID(profile.bundleID) else {
            throw ClaudeManagerError.invalidBundleID(profile.bundleID)
        }

        if fileManager.fileExists(atPath: profile.appPath) {
            profile = try profileForForcedRebuild(over: profile, force: request.force)
        }
        // Refuse whenever this profile's user-data-dir already has a live instance,
        // not only on a forced rebuild — otherwise re-adding a name whose bundle was
        // deleted while running would rebuild under the live process.
        if let pid = runningPID(for: profile) {
            throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
        }

        try ensureInstallDirectoryWritable()

        let reused = directoryHasContents(profile.profilePath)
        let profileDirExisted = fileManager.fileExists(atPath: profile.profilePath)
        try fileManager.createDirectory(at: profile.profileURL, withIntermediateDirectories: true)

        let iconChanged: Bool
        do {
            let icns = try iconPipeline.makeBadgeICNS(
                realClaude: realClaude,
                label: profile.label,
                color: profile.color,
                style: configuration.badgeStyle
            )
            iconChanged = try bundle.build(
                profile: profile, realBinaryPath: realClaude.binaryURL.path, icnsData: icns
            )
        } catch {
            // A failed add must leave nothing behind: without this the profile dir we
            // just created outlives the failure and Doctor reports it as an orphan the
            // user never made. Only ever removes a dir this call created and left
            // empty — never pre-existing profile data.
            if !profileDirExisted, !directoryHasContents(profile.profilePath) {
                try? fileManager.removeItem(at: profile.profileURL)
            }
            throw error
        }

        // Register so Finder/LaunchServices pick up the icon — never flash the screen. A
        // pinned tile can only be stale when a bundle was already here (forced rebuild or a
        // trashed twin) *and* the icon changed; that tile is repainted by the app's opt-in
        // "Refresh Dock now". A brand-new path has nothing cached.
        iconCache.register(appURL: profile.appURL)
        let dockRefreshPending =
            iconChanged && (request.force || bundle.hasTrashedTwin(appURL: profile.appURL))

        // Pre-seed the clone's managed-config overlay (disable its updater). Best-effort:
        // a config hiccup must never fail launcher creation — Doctor surfaces a miss.
        try? reconcileManagedConfig(for: profile)

        return AddResult(
            profile: profile, reusedProfileData: reused, dockRefreshPending: dockRefreshPending
        )
    }

    /// Launch the profile (a fresh instance; the launcher's own guard prevents
    /// duplicates on the same user-data-dir).
    public func open(_ profile: Profile) throws {
        try runner.runChecked(CoreConstants.openPath, ["-n", profile.appPath])
    }

    /// Stop the running instance, polling until it exits or the timeout elapses.
    /// Graceful (SIGTERM) unless `force` requests SIGKILL. Delegates the signal +
    /// poll loop to `stopProcess` (see `ProfileStore+Stop.swift`), differing from
    /// `stopDefault` only in keying on this profile's pid.
    @discardableResult
    public func stop(
        _ profile: Profile,
        force: Bool,
        pollInterval: TimeInterval = 0.5,
        maxPolls: Int = 20
    ) async -> StopOutcome {
        guard let pid = runningPID(for: profile) else { return .notRunning }
        return await stopProcess(pid: pid, force: force, pollInterval: pollInterval, maxPolls: maxPolls) {
            runningPID(for: profile) == nil
        }
    }

    // MARK: - Helpers

    /// Fail fast if the real Claude binary this store wraps is absent. Every mutation
    /// that bakes `realClaude.binaryURL` into a launcher (`add`, `update`, `rebuild`,
    /// `rebuildAll`) shares this precondition. `open` is deliberately *not* guarded:
    /// it launches a launcher whose real-binary path was baked in at build time —
    /// surfacing a stale one of those is `Doctor`'s job, not this check's.
    /// `internal`, not `private`: the rebuild paths live in `ProfileStore+Rebuild`.
    func ensureRealBinaryPresent() throws {
        guard realClaude.binaryExists(fileManager: fileManager) else {
            throw ClaudeManagerError.realClaudeNotFound
        }
    }

    /// PID of this profile's running instance, or `nil`. Public so a caller can activate
    /// a running profile by pid instead of relaunching its launcher just to self-exit.
    public func runningPID(for profile: Profile) -> Int32? {
        processProbe.mainPID(forProfilePath: profile.profilePath, realBinaryPath: realClaude.binaryURL.path)
    }

    func directoryHasContents(_ path: String) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return false }
        let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return !contents.isEmpty
    }

    func diskSize(of path: String) -> String? {
        guard fileManager.fileExists(atPath: path),
              let output = try? runner.run(CoreConstants.duPath, ["-sh", path]),
              output.succeeded
        else { return nil }
        return output.trimmedOutput.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    func ensureInstallDirectoryWritable() throws {
        let dir = configuration.installDirectory
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
            // A regular file at the install path would pass the writability check
            // but fail confusingly when we create Contents/ under it.
            guard isDirectory.boolValue else {
                throw ClaudeManagerError.installDirectoryNotWritable(path: dir.path)
            }
        } else {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw ClaudeManagerError.installDirectoryNotWritable(path: dir.path)
            }
        }
        guard fileManager.isWritableFile(atPath: dir.path) else {
            throw ClaudeManagerError.installDirectoryNotWritable(path: dir.path)
        }
    }
}

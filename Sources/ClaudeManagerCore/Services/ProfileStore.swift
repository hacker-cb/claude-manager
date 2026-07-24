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
}

public struct RemovalResult: Sendable {
    public let trashedAppURL: URL?
    public let profilePath: String
    public let purgedProfileData: Bool
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
        iconCache = IconCache(runner: runner, fileManager: fileManager)
        iconPipeline = IconPipeline(packer: IcnsPacker(runner: runner, fileManager: fileManager))
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

    /// The launcher list *and* the default-account status from a single `ps` sweep, so a
    /// refresh pays for one process scan instead of two (`list` and the default-pid probe
    /// each swept the table independently). The one read the app's `refresh` uses.
    public func snapshot(measuringSizes: Bool = false) -> StoreSnapshot {
        let mains = processProbe.allClaudeMains()
        return StoreSnapshot(
            profiles: list(measuringSizes: measuringSizes, mains: mains),
            primaryAccount: PrimaryAccountStatus(pid: defaultPID(in: mains))
        )
    }

    /// All managed launchers with live running state (and optional disk usage). Also
    /// stamps each with the Claude version it's running vs the one on disk, so a
    /// launcher left on an older build surfaces as "restart to update".
    public func list(measuringSizes: Bool = false) -> [ManagedProfile] {
        list(measuringSizes: measuringSizes, mains: processProbe.allClaudeMains())
    }

    /// `list`, but reusing an already-fetched process sweep for the running-version map — so
    /// `snapshot` can share one `ps` across the launcher list and the default-account status.
    /// `private`: an implementation detail shared only by `snapshot` and the no-arg `list`.
    private func list(measuringSizes: Bool, mains: [ClaudeInstance]) -> [ManagedProfile] {
        let availableVersion = realClaude.version(fileManager: fileManager)
        let runningVersions = processProbe.runningVersionsByProfilePath(from: mains)
        return bundle.scan(installDirectory: configuration.installDirectory).map { discovered in
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

        let profile = draft(
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

        if fileManager.fileExists(atPath: profile.appPath), !request.force {
            throw ClaudeManagerError.launcherAlreadyExists(path: profile.appPath)
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

        do {
            let icns = try iconPipeline.makeBadgeICNS(
                realClaude: realClaude,
                label: profile.label,
                color: profile.color,
                style: configuration.badgeStyle
            )
            try bundle.build(profile: profile, realBinaryPath: realClaude.binaryURL.path, icnsData: icns)
        } catch {
            // A failed add must leave nothing behind: without this the profile dir we
            // just created outlives the failure and Doctor reports it as an orphan the
            // user never made. Only ever removes a dir this call created and left
            // empty — never pre-existing account data.
            if !profileDirExisted, !directoryHasContents(profile.profilePath) {
                try? fileManager.removeItem(at: profile.profileURL)
            }
            throw error
        }

        // Skip the screen-flashing Dock restart for a brand-new bundle (nothing
        // cached for its path); restart on a forced rebuild or a trashed twin.
        let restartDock = request.force || bundle.hasTrashedTwin(appURL: profile.appURL)
        iconCache.refresh(appURL: profile.appURL, restartDock: restartDock)

        // Pre-seed the clone's managed-config overlay (disable its updater). Best-effort:
        // a config hiccup must never fail launcher creation — Doctor surfaces a miss.
        try? reconcileManagedConfig(for: profile)

        return AddResult(profile: profile, reusedProfileData: reused)
    }

    /// Apply edits by rebuilding the launcher, trashing the old bundle on rename.
    @discardableResult
    public func update(original: Profile, to updated: Profile) throws -> Profile {
        try ensureRealBinaryPresent()
        if let pid = runningPID(for: original) {
            throw ClaudeManagerError.profileRunning(name: original.name, pid: pid)
        }
        guard Profile.isValidName(updated.name) else {
            throw ClaudeManagerError.invalidProfileName(updated.name)
        }
        guard Profile.isValidDisplayName(updated.displayName) else {
            throw ClaudeManagerError.invalidDisplayName(updated.displayName)
        }
        guard Profile.isValidBundleID(updated.bundleID) else {
            throw ClaudeManagerError.invalidBundleID(updated.bundleID)
        }
        // Re-derive the bundle path from the install dir + validated display name
        // rather than trusting the caller's appPath — the only injection-proof
        // source for where the .app lands.
        var updated = updated
        updated.appPath = configuration.installDirectory
            .appendingPathComponent("\(updated.displayName).app").path

        let renaming = updated.appPath != original.appPath
        if renaming, fileManager.fileExists(atPath: updated.appPath) {
            throw ClaudeManagerError.launcherAlreadyExists(path: updated.appPath)
        }

        try ensureInstallDirectoryWritable()
        try fileManager.createDirectory(at: updated.profileURL, withIntermediateDirectories: true)

        let icns = try iconPipeline.makeBadgeICNS(
            realClaude: realClaude,
            label: updated.label,
            color: updated.color,
            style: configuration.badgeStyle
        )
        try bundle.build(profile: updated, realBinaryPath: realClaude.binaryURL.path, icnsData: icns)

        if renaming, fileManager.fileExists(atPath: original.appPath) {
            _ = try? bundle.moveToTrash(appURL: original.appURL)
        }

        // In-place rebuild has a stale cached icon → restart the Dock; a fresh
        // path only needs a restart if a same-named twin is in the Trash.
        let restartDock = !renaming || bundle.hasTrashedTwin(appURL: updated.appURL)
        iconCache.refresh(appURL: updated.appURL, restartDock: restartDock)
        // Seed the (possibly relocated) profile's overlay, as add/rebuild do.
        try? reconcileManagedConfig(for: updated)
        return updated
    }

    /// Move the launcher to Trash (and optionally delete the profile data).
    @discardableResult
    public func remove(_ profile: Profile, purgeProfile: Bool) throws -> RemovalResult {
        guard fileManager.fileExists(atPath: profile.appPath) else {
            // Consistent domain error instead of a raw CocoaError from trashItem.
            throw ClaudeManagerError.launcherNotFound(name: profile.name)
        }
        if let pid = runningPID(for: profile) {
            throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
        }
        let trashed = try bundle.moveToTrash(appURL: profile.appURL)
        var purged = false
        if purgeProfile {
            // Never delete data another launcher still points at (the launcher we
            // just trashed is already gone from the scan).
            let survivors = bundle.scan(installDirectory: configuration.installDirectory)
            let sharedByAnother = survivors.contains { $0.marker.profile == profile.profilePath }
            if !sharedByAnother {
                if fileManager.fileExists(atPath: profile.profilePath) {
                    try fileManager.removeItem(at: profile.profileURL)
                    purged = true
                }
                // Purge the `<profilePath>-3p` overlay sibling too — it is created
                // independently of the data dir, so remove it even if the data dir is
                // already gone (removeOverlay no-ops when absent). Guard a name collision:
                // if another launcher's user-data dir *is* that `-3p` path, it's that
                // account's data, not our overlay — leave it alone.
                let overlayPath = ManagedConfigWriter
                    .localTierURL(forUserDataPath: profile.profilePath).standardizedFileURL.path
                let overlayIsAnothersData = survivors.contains {
                    URL(fileURLWithPath: $0.marker.profile).standardizedFileURL.path == overlayPath
                }
                if !overlayIsAnothersData {
                    try? managedConfigWriter.removeOverlay(userDataPath: profile.profilePath)
                }
            }
        }
        return RemovalResult(
            trashedAppURL: trashed,
            profilePath: profile.profilePath,
            purgedProfileData: purged
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

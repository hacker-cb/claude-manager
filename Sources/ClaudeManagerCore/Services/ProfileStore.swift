import Darwin
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

    public init(
        installDirectory: URL,
        defaultProfilesDirectory: URL,
        badgeStyle: BadgeStyle = .default
    ) {
        self.installDirectory = installDirectory
        self.defaultProfilesDirectory = defaultProfilesDirectory
        self.badgeStyle = badgeStyle
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

/// The façade the app talks to: scan, add, remove, open, stop, edit, regenerate
/// icons, and run diagnostics. Composed of small injectable services so the whole
/// thing is testable against temp directories and a mock `CommandRunner`.
public struct ProfileStore {
    public let realClaude: RealClaude
    public let configuration: ProfileStoreConfiguration

    let runner: CommandRunner
    let fileManager: FileManager
    let bundle: LauncherBundle
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
        bundle = LauncherBundle(fileManager: fileManager)
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

    /// All managed launchers with live running state (and optional disk usage).
    public func list(measuringSizes: Bool = false) -> [ManagedProfile] {
        bundle.scan(installDirectory: configuration.installDirectory).map { discovered in
            let profile = discovered.profile
            let pid = runningPID(for: profile)
            let size = measuringSizes ? diskSize(of: profile.profilePath) : nil
            return ManagedProfile(profile: profile, pid: pid, diskSize: size)
        }
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
        let resolvedLabel = (label?.isEmpty == false ? label! : Profile.defaultLabel(for: name)).uppercased()
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
        try fileManager.createDirectory(at: profile.profileURL, withIntermediateDirectories: true)

        let icns = try iconPipeline.makeBadgeICNS(
            realClaude: realClaude,
            label: profile.label,
            color: profile.color,
            style: configuration.badgeStyle
        )
        try bundle.build(profile: profile, realBinaryPath: realClaude.binaryURL.path, icnsData: icns)

        // Skip the screen-flashing Dock restart for a brand-new bundle (nothing
        // cached for its path); restart on a forced rebuild or a trashed twin.
        let restartDock = request.force || bundle.hasTrashedTwin(appURL: profile.appURL)
        iconCache.refresh(appURL: profile.appURL, restartDock: restartDock)

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
        if purgeProfile, fileManager.fileExists(atPath: profile.profilePath) {
            // Never delete data another launcher still points at (the launcher we
            // just trashed is already gone from the scan).
            let sharedByAnother = bundle
                .scan(installDirectory: configuration.installDirectory)
                .contains { $0.marker.profile == profile.profilePath }
            if !sharedByAnother {
                try fileManager.removeItem(at: profile.profileURL)
                purged = true
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
    ///
    /// Polls with `Task.sleep`, not `Thread.sleep`: a stubborn process can keep us
    /// waiting up to `pollInterval * maxPolls` (~10s by default), and this runs off
    /// the main actor on the shared cooperative pool. Suspending instead of blocking
    /// keeps that thread free for other work while we wait.
    ///
    /// Cancellation stops the wait: a cancelled `Task.sleep` throws, and we break out
    /// rather than swallowing it and busy-spinning `runningPID` for the rest of the
    /// budget. `pollInterval` is clamped only to keep a negative value out of
    /// `Duration.seconds`; a zero or tiny interval still returns near-immediately, so
    /// the loop can spin fast — bounded, either way, only by the `maxPolls` cap.
    @discardableResult
    public func stop(
        _ profile: Profile,
        force: Bool,
        pollInterval: TimeInterval = 0.5,
        maxPolls: Int = 20
    ) async -> StopOutcome {
        guard let pid = runningPID(for: profile) else { return .notRunning }
        _ = signalSender(pid, force ? SIGKILL : SIGTERM)
        let interval = Duration.seconds(max(0, pollInterval))
        for _ in 0 ..< maxPolls {
            do {
                try await Task.sleep(for: interval)
            } catch {
                break // cancelled — stop waiting
            }
            if runningPID(for: profile) == nil { return .stopped }
        }
        return .stillRunning(pid: pid)
    }

    /// Rebuild one launcher's badge icon.
    public func regenerateIcon(for profile: Profile, restartDock: Bool = true) throws {
        try ensureRealBinaryPresent()
        guard fileManager.fileExists(atPath: profile.appPath) else {
            throw ClaudeManagerError.launcherNotFound(name: profile.name)
        }
        let icns = try iconPipeline.makeBadgeICNS(
            realClaude: realClaude,
            label: profile.label,
            color: profile.color,
            style: configuration.badgeStyle
        )
        try icns.write(to: profile.appURL.appendingPathComponent("Contents/Resources/Badge.icns"))
        iconCache.refresh(appURL: profile.appURL, restartDock: false)
        if restartDock { iconCache.restartDock() }
    }

    /// Rebuild every launcher's icon, restarting the Dock once for the batch.
    @discardableResult
    public func regenerateAllIcons() throws -> [Profile] {
        let profiles = list().map(\.profile)
        for profile in profiles {
            try regenerateIcon(for: profile, restartDock: false)
        }
        if !profiles.isEmpty { iconCache.restartDock() }
        return profiles
    }

    /// All running Claude instances across every bundle (for the status view).
    public func runningInstances() -> [ClaudeInstance] {
        processProbe.allClaudeMains()
    }

    /// Health check.
    public func doctor() -> [Diagnostic] {
        Doctor(
            realClaude: realClaude,
            configuration: configuration,
            bundle: bundle,
            processProbe: processProbe,
            fileManager: fileManager
        ).run()
    }

    // MARK: - Helpers

    /// Fail fast if the real Claude binary this store wraps is absent. Every
    /// mutation that bakes `realClaude.binaryURL` into a launcher (`add`, `update`)
    /// or reads its icon (`regenerateIcon`) shares this precondition instead of
    /// each trusting `realClaude` blindly.
    ///
    /// `open` is deliberately *not* guarded here: it never references `realClaude`,
    /// only launches an existing launcher whose real-binary path was baked in at
    /// build time. Checking the *currently resolved* app would neither cover that
    /// baked path nor catch it going stale — surfacing a stale launcher is
    /// `Doctor`'s job.
    private func ensureRealBinaryPresent() throws {
        guard realClaude.binaryExists(fileManager: fileManager) else {
            throw ClaudeManagerError.realClaudeNotFound
        }
    }

    func runningPID(for profile: Profile) -> Int32? {
        processProbe.mainPID(
            forProfilePath: profile.profilePath,
            realBinaryPath: realClaude.binaryURL.path
        )
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

import Foundation

/// Health check over the real app, every managed launcher, orphaned profile dirs,
/// and duplicate running instances. Produces a flat, ordered list of diagnostics.
public struct Doctor {
    let realClaude: RealClaude?
    let configuration: ProfileStoreConfiguration
    let bundle: LauncherBundle
    let processProbe: ProcessProbe
    let fileManager: FileManager
    let managedConfigWriter: ManagedConfigWriter
    let codeSigner: CodeSigner

    /// `bundle` and `codeSigner` are required, not defaulted: both would otherwise
    /// silently fall back to a fresh `SystemCommandRunner` and bypass the caller's
    /// injected one — which is exactly what the test suite relies on not happening.
    public init(
        realClaude: RealClaude?,
        configuration: ProfileStoreConfiguration,
        bundle: LauncherBundle,
        codeSigner: CodeSigner,
        processProbe: ProcessProbe,
        fileManager: FileManager = .default,
        managedConfigWriter: ManagedConfigWriter? = nil
    ) {
        self.realClaude = realClaude
        self.configuration = configuration
        self.bundle = bundle
        self.codeSigner = codeSigner
        self.processProbe = processProbe
        self.fileManager = fileManager
        self.managedConfigWriter = managedConfigWriter ?? ManagedConfigWriter(fileManager: fileManager)
    }

    /// - Parameter managingUpdates: whether Claude Manager is the one updating Claude. It
    ///   decides what the default profile's overlay *should* say, and the check reverses with
    ///   it: with this app in charge the updater must be off, and with Claude in charge it
    ///   must be on. A check that only ever expected one of the two would report the working
    ///   configuration as broken.
    public func run(managingUpdates: Bool) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        diagnostics.append(realClaudeDiagnostic())

        let scan = bundle.scan(installDirectory: configuration.installDirectory)
        let discovered = scan.launchers
        var knownProfiles = Set<String>()
        for launcher in discovered {
            knownProfiles.insert(launcher.marker.profile)
            diagnostics.append(launcherDiagnostic(for: launcher))
        }

        diagnostics.append(contentsOf: signatureDiagnostics(discovered))
        diagnostics.append(contentsOf: staleLauncherDiagnostics(discovered))
        diagnostics.append(contentsOf: claudeVersionSkewDiagnostics(discovered))
        diagnostics.append(contentsOf: managedConfigDiagnostics(discovered, managingUpdates: managingUpdates))
        diagnostics.append(contentsOf: stagedUpdateDiagnostics())
        diagnostics.append(
            contentsOf: orphanProfileDiagnostics(known: knownProfiles, scan: scan)
        )
        diagnostics.append(contentsOf: duplicateInstanceDiagnostics())
        return diagnostics
    }

    /// How long a run of failed checks is worth reporting. Claude ships every few days, so a
    /// week of silence is well past "the feed happened to be down".
    public static let staleUpdateCheckThreshold: TimeInterval = 7 * 24 * 3600

    /// A warning the **app** appends when this app owns Claude's updates and has not managed
    /// to ask about one in a long time.
    ///
    /// This is the failure the switch-over creates and nothing else would catch. Claude's own
    /// updater is off, so it will not step in; a failed check is deliberately silent (a laptop
    /// is offline constantly, and a banner for that would be noise); and the healthy state —
    /// updater off, this app in charge — is exactly what Doctor now reports as fine. A
    /// corporate proxy blocking the release feed, or a feed that changed shape, would
    /// therefore leave Claude frozen on an old build indefinitely with nothing saying so.
    ///
    /// `nil` when this app is not managing updates, or when the feed answered recently.
    public static func staleUpdateCheckDiagnostic(
        managingUpdates: Bool,
        lastSuccess: Date?,
        now: Date = Date(),
        threshold: TimeInterval = staleUpdateCheckThreshold
    ) -> Diagnostic? {
        guard managingUpdates else { return nil }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < threshold { return nil }
        let detail = lastSuccess.map {
            "Last successful check: \(Self.dayCount(from: $0, to: now)) days ago."
        } ?? "No successful check has been recorded."
        return Diagnostic(
            severity: .warning,
            title: "Claude has not been checked for updates in a while — and its own updater is off",
            detail: detail + " Claude Manager is responsible for updating Claude, so if this "
                + "persists Claude will stay on its current build. Check the network, or turn "
                + "off \"Let Claude Manager update Claude\" in Settings to hand the job back."
        )
    }

    private static func dayCount(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 86400))
    }

    /// A warning the **app** appends when the deep-link broker is on but the app isn't set to
    /// launch at login. It can't live in `run()` — both inputs are app-layer, not core state.
    /// The broker's `claude://` hold is held only while Claude Manager runs, so with it closed
    /// a profile you open can take the scheme over and its links stop routing through the
    /// picker; keeping the app resident (launch at login) closes that gap. `nil` when the
    /// broker is off or launch-at-login is already on.
    public static func deepLinkResidencyDiagnostic(
        brokerEnabled: Bool,
        launchAtLoginEnabled: Bool
    ) -> Diagnostic? {
        guard brokerEnabled, !launchAtLoginEnabled else { return nil }
        return Diagnostic(
            severity: .warning,
            title: "Deep links need Claude Manager running — turn on Launch at login",
            detail: "While Claude Manager is closed, a profile you open can take over claude:// "
                + "and its links stop going through the profile picker."
        )
    }

    // MARK: - Individual checks

    private func realClaudeDiagnostic() -> Diagnostic {
        guard let realClaude else {
            return Diagnostic(severity: .error, title: "Real Claude.app is missing")
        }
        guard realClaude.binaryExists(fileManager: fileManager) else {
            // The bundle resolved but its executable is absent — distinct from a
            // truly missing app (e.g. a broken/partial update).
            return Diagnostic(
                severity: .error,
                title: "Real Claude.app has no executable",
                detail: PathUtils.abbreviatingHome(realClaude.binaryURL.path)
            )
        }
        let version = realClaude.version(fileManager: fileManager).map { "v\($0)" } ?? "version unknown"
        return Diagnostic(
            severity: .ok,
            title: "Real Claude.app \(version)",
            detail: PathUtils.abbreviatingHome(realClaude.appURL.path)
        )
    }

    private func launcherDiagnostic(for launcher: LauncherBundle.Discovered) -> Diagnostic {
        let profile = launcher.profile
        let scriptURL = launcher.appURL.appendingPathComponent("Contents/MacOS/launcher")
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return Diagnostic(severity: .error, title: "\(profile.displayName): launcher script missing")
        }
        if let realBinary = realClaude?.binaryURL.path, !script.contains(realBinary) {
            return Diagnostic(
                severity: .error,
                title: "\(profile.displayName): script does not point at the real binary",
                detail: PathUtils.abbreviatingHome(realBinary)
            )
        }
        if !fileManager.fileExists(atPath: profile.profilePath) {
            return Diagnostic(
                severity: .warning,
                title: "\(profile.displayName): profile dir missing — created on launch",
                detail: PathUtils.abbreviatingHome(profile.profilePath)
            )
        }
        return Diagnostic(
            severity: .ok,
            title: "\(profile.displayName): ok",
            detail: PathUtils.abbreviatingHome(profile.profilePath)
        )
    }

    /// Whether each launcher carries a signature macOS would accept. Split from
    /// `launcherDiagnostic` because it is the one failure that leaves every other check
    /// green: an unsigned or seal-broken bundle has its script, its marker and its
    /// profile dir all intact, and still cannot start.
    ///
    /// Two distinct causes, reported as errors — the launcher does not run either way:
    /// a bundle predating ad-hoc signing (wrapper < 3, no signature was ever written),
    /// and a v3+ bundle whose seal has since been broken (something wrote into it).
    private func signatureDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        discovered.compactMap { launcher in
            if launcher.isUnrunnable {
                return Diagnostic(
                    severity: .error,
                    title: "\(launcher.displayName): unsigned — macOS will not run it, rebuild to fix",
                    detail: "wrapper v\(launcher.wrapperVersion) predates launcher signing "
                        + "(v\(CoreConstants.minimumRunnableWrapperVersion))"
                )
            }
            guard !codeSigner.isValidlySigned(bundleURL: launcher.appURL) else { return nil }
            return Diagnostic(
                severity: .error,
                title: "\(launcher.displayName): signature is broken — macOS will not run it, rebuild to fix",
                detail: PathUtils.abbreviatingHome(launcher.appURL.path)
            )
        }
    }

    /// A soft warning per launcher built by an older wrapper than the current one —
    /// it still runs, but a rebuild would refresh its script/Info.plist (e.g. to run
    /// native instead of under Rosetta). Separate from `launcherDiagnostic` so an
    /// otherwise-ok launcher is reported as both "ok" and "stale". A launcher that is
    /// *unrunnable* is left to `signatureDiagnostics`, so "rebuild is optional" wording
    /// never lands on a launcher that cannot start.
    private func staleLauncherDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        discovered.filter { $0.isStale && !$0.isUnrunnable }.map { launcher in
            Diagnostic(
                severity: .warning,
                title: "\(launcher.displayName): built by an older launcher format — rebuild to update",
                detail: "wrapper v\(launcher.wrapperVersion) < v\(CoreConstants.currentWrapperVersion)"
            )
        }
    }

    /// A warning per running launcher whose live instance is on an older Claude than
    /// the app now on disk — Claude.app auto-updated in place while the instance kept
    /// its launch-time version. The fix is a restart, not a rebuild (so it's distinct
    /// from `staleLauncherDiagnostics`). Only managed launchers are checked; other
    /// Claude processes (the real app, unmanaged copies) are ignored.
    private func claudeVersionSkewDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        guard let available = realClaude?.version(fileManager: fileManager) else { return [] }
        let launcherByProfile = Dictionary(
            discovered.map { ($0.marker.profile, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return processProbe.allClaudeMains().compactMap { instance in
            guard let profilePath = instance.profilePath,
                  let launcher = launcherByProfile[profilePath],
                  let running = instance.runningVersion,
                  VersionOrder.isNewer(available, than: running)
            else { return nil }
            return Diagnostic(
                severity: .warning,
                title: "\(launcher.displayName): running v\(running) — Claude v\(available) available, restart to update",
                detail: PathUtils.abbreviatingHome(profilePath)
            )
        }
    }

    /// Managed-config overlay health for the cloned launchers. With no launchers there
    /// is nothing to report. When Claude is MDM-managed the local overlay is overridden,
    /// so we surface one *informational* (`.ok`) note — not a standing warning the user
    /// can't clear — and skip the per-clone checks (the managed tier owns the policy).
    /// Otherwise, warn once per distinct user-data-dir whose overlay does not disable
    /// the updater — a best-effort write that silently failed, or a profile predating
    /// this feature that has not yet been reconciled (reopening Claude Manager fixes it).
    private func managedConfigDiagnostics(
        _ discovered: [LauncherBundle.Discovered], managingUpdates: Bool
    ) -> [Diagnostic] {
        // Nothing on disk to manage, and nothing this app is *supposed* to have written.
        //
        // The last clause is the one that changed with managed updates: an absent overlay
        // used to mean "nothing to check", because the default profile was deliberately left
        // untouched. Now, when this app is in charge of updating, an absent overlay is
        // exactly the state worth reporting — Claude's own updater is still on, and it will
        // force-restart the default profile to install a build of its own.
        let defaultPath = configuration.defaultProfileUserDataPath
        guard !discovered.isEmpty
            || managedConfigWriter.overlayExists(userDataPath: defaultPath)
            || managingUpdates else { return [] }

        if managedConfigWriter.mdmPresent {
            let path = managedConfigWriter.presentManagedPreferencesURL?.path
                ?? CoreConstants.claudeManagedPreferencesPaths.first ?? ""
            return [Diagnostic(
                severity: .ok,
                title: "Claude is MDM-managed — per-profile auto-update control is handled by managed preferences",
                detail: PathUtils.abbreviatingHome(path)
            )]
        }
        return cloneOverlayDiagnostics(discovered)
            + defaultProfileOverlayDiagnostics(defaultPath, managingUpdates: managingUpdates)
    }

    /// Warn once per distinct clone user-data-dir whose overlay is wrong: the updater not
    /// disabled, **or** a stale `disableDeepLinkRegistration` still present. The second case
    /// is invisible to `isSatisfied(.clone())` — that only checks the keys we *want* — yet it
    /// makes Claude drop every forwarded deep link, so it needs its own `hasFlag` check.
    private func cloneOverlayDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        let expected = ProfileManagedConfig.clone()
        var seen = Set<String>()
        return discovered.compactMap { launcher -> Diagnostic? in
            let profilePath = launcher.marker.profile
            guard seen.insert(profilePath).inserted else { return nil }
            if !managedConfigWriter.isSatisfied(expected, userDataPath: profilePath) {
                return Diagnostic(
                    severity: .warning,
                    title: "\(launcher.displayName): managed config not applied — reopen Claude Manager or rebuild",
                    detail: PathUtils.abbreviatingHome(profilePath)
                )
            }
            // Satisfies `.clone()` (updater disabled) but an older build also left the deep-link
            // key — Claude drops forwarded links until this profile is restarted. Reopening CM
            // reconciles the file; the running instance still needs a restart to pick it up.
            if managedConfigWriter.hasFlag(
                ProfileManagedConfig.disableDeepLinkRegistrationKey, userDataPath: profilePath
            ) {
                return Diagnostic(
                    severity: .warning,
                    title: "\(launcher.displayName): deep-link registration is suppressed — reopen Claude Manager, then restart this profile",
                    detail: PathUtils.abbreviatingHome(profilePath)
                )
            }
            return nil
        }
    }

    /// What the default profile's overlay should say depends on who is updating Claude, and
    /// the check reverses with it.
    ///
    /// With Claude Manager in charge the updater must be **off**: left on, Claude downloads
    /// and stages builds of its own and force-restarts the default profile every ~72 h to
    /// install one — `autoUpdaterEnforcementHours` cannot be disabled, only shortened, and
    /// nothing but `disableAutoUpdates` keeps that timer from arming. With Claude in charge
    /// it must be **on**, or nothing updates the app at all.
    ///
    /// `disableDeepLinkRegistration` is wrong either way: the `claude://` handler is held by
    /// the event-driven guard, and that key makes Claude drop forwarded links.
    private func defaultProfileOverlayDiagnostics(
        _ defaultPath: String, managingUpdates: Bool
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let updaterDisabled = managedConfigWriter.isSatisfied(
            ProfileManagedConfig(disableAutoUpdates: true), userDataPath: defaultPath
        )
        if managingUpdates, !updaterDisabled {
            diagnostics.append(Diagnostic(
                severity: .warning,
                title: "Default profile: Claude's own updater is still on — reopen Claude Manager to switch it off",
                detail: PathUtils.abbreviatingHome(defaultPath)
            ))
        }
        if !managingUpdates, updaterDisabled {
            diagnostics.append(Diagnostic(
                severity: .warning,
                title: "Default profile: auto-updates are disabled — reopen Claude Manager to restore them",
                detail: PathUtils.abbreviatingHome(defaultPath)
            ))
        }
        if managedConfigWriter.hasFlag(
            ProfileManagedConfig.disableDeepLinkRegistrationKey, userDataPath: defaultPath
        ) {
            diagnostics.append(Diagnostic(
                severity: .warning,
                title: "Default profile: deep-link registration is suppressed — reopen Claude Manager to restore it",
                detail: PathUtils.abbreviatingHome(defaultPath)
            ))
        }
        return diagnostics
    }

    /// The profiles directory's contents that no launcher claims.
    ///
    /// Both halves are spelling-sensitive, and getting either wrong tells the user that a
    /// directory holding their Anthropic login and chat history is safe to delete. So the
    /// listing goes through `visibleContents(ofDirectoryAt:)` — whose doc comment explains what
    /// the URL overload would lose here — and the "is it claimed" test compares canonical
    /// paths, since a marker records whatever spelling the profile was created with (iCloud's
    /// Desktop & Documents replaces `~/Documents` with a symlink, and the profiles directory is
    /// user-settable).
    private func orphanProfileDiagnostics(
        known: Set<String>,
        scan: LauncherBundle.Scan
    ) -> [Diagnostic] {
        // `known` comes from a scan of the install directory, and `LauncherBundle.scan` reports
        // an unreadable one as holding no launchers. Reading that as "nobody claims any of
        // these directories" is the misreading its doc comment warns callers about, and here
        // it would label every live profile — each holding a login and a chat history — as
        // safe to delete. A launcher folder that was renamed, unmounted, or had its
        // permissions changed is exactly that state, so say the check could not run.
        guard scan.isComplete else {
            return [Diagnostic(
                severity: .warning,
                title: "Cannot read the launcher folder — orphan-profile check skipped",
                detail: PathUtils.abbreviatingHome(configuration.installDirectory.path)
            )]
        }
        let dir = configuration.defaultProfilesDirectory
        // The default profile owns no launcher, so it is in no marker and no scan — and the
        // profiles folder is user-settable, so it can be pointed at the directory holding it
        // (`~/Library/Application Support`). Without this it is reported as an orphan: the
        // user's primary Anthropic login and chat history, named as safe to delete.
        // `purgeProfileData` guards the same blind spot with `keptForDefaultProfile`.
        let claimed = Set(
            known.union([configuration.defaultProfileUserDataPath])
                .map { PathUtils.canonicalPath($0) }
        )

        return fileManager.visibleContents(ofDirectoryAt: dir, skippingFlaggedHidden: true)
            .sorted { $0.path < $1.path }
            .filter { entry in
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
                    && !claimed.contains(PathUtils.canonicalPath(entry.path))
                    && !entry.lastPathComponent.hasPrefix("_")
                    // Skip our managed-config tier (`<userData>-3p`) — identified by its
                    // `configLibrary/_meta.json`, not the name suffix, so a profile a user
                    // happens to name `…-3p` is still orphan-scanned.
                    && !isManagedConfigTier(entry)
            }
            .map {
                Diagnostic(
                    severity: .warning,
                    title: "Orphan profile (no launcher)",
                    detail: PathUtils.abbreviatingHome($0.path)
                )
            }
    }

    /// Whether `dir` is a Claude-Manager managed-config tier (`<userData>-3p`), identified
    /// by its `configLibrary/_meta.json` sentinel rather than the `-3p` name suffix alone
    /// (a user may legitimately name a profile ending in `-3p`).
    private func isManagedConfigTier(_ dir: URL) -> Bool {
        dir.lastPathComponent.hasSuffix("-3p")
            && fileManager.fileExists(
                atPath: dir.appendingPathComponent("configLibrary/_meta.json").path
            )
    }

    private func duplicateInstanceDiagnostics() -> [Diagnostic] {
        var byProfile: [String: [Int32]] = [:]
        for instance in processProbe.allClaudeMains() {
            guard let profile = instance.profilePath else { continue }
            byProfile[profile, default: []].append(instance.pid)
        }
        return byProfile
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { profile, pids in
                let pidList = pids.sorted().map(String.init).joined(separator: ", ")
                return Diagnostic(
                    severity: .warning,
                    title: "Duplicate instances on one profile",
                    detail: "\(PathUtils.abbreviatingHome(profile)) — pids \(pidList)"
                )
            }
    }
}

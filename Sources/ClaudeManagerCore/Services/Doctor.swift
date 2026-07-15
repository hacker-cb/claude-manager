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

    public init(
        realClaude: RealClaude?,
        configuration: ProfileStoreConfiguration,
        bundle: LauncherBundle = LauncherBundle(),
        processProbe: ProcessProbe,
        fileManager: FileManager = .default,
        managedConfigWriter: ManagedConfigWriter? = nil
    ) {
        self.realClaude = realClaude
        self.configuration = configuration
        self.bundle = bundle
        self.processProbe = processProbe
        self.fileManager = fileManager
        self.managedConfigWriter = managedConfigWriter ?? ManagedConfigWriter(fileManager: fileManager)
    }

    public func run() -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        diagnostics.append(realClaudeDiagnostic())

        let discovered = bundle.scan(installDirectory: configuration.installDirectory)
        var knownProfiles = Set<String>()
        for launcher in discovered {
            knownProfiles.insert(launcher.marker.profile)
            diagnostics.append(launcherDiagnostic(for: launcher))
        }

        diagnostics.append(contentsOf: staleLauncherDiagnostics(discovered))
        diagnostics.append(contentsOf: claudeVersionSkewDiagnostics(discovered))
        diagnostics.append(contentsOf: managedConfigDiagnostics(discovered))
        diagnostics.append(contentsOf: stagedUpdateDiagnostics())
        diagnostics.append(contentsOf: orphanProfileDiagnostics(known: knownProfiles))
        diagnostics.append(contentsOf: duplicateInstanceDiagnostics())
        return diagnostics
    }

    /// A warning when a Claude update is staged but not applied — ShipIt can't swap
    /// `/Applications/Claude.app` while any instance runs, the "Update didn't complete"
    /// case. Distinct from the per-launcher version-skew warning (there the swap happened).
    private func stagedUpdateDiagnostics() -> [Diagnostic] {
        guard let realClaude,
              let staged = StagedUpdateProbe(
                  realClaude: realClaude,
                  shipItStatePath: configuration.shipItStatePath,
                  fileManager: fileManager
              ).probe()
        else { return [] }
        let running = processProbe.allClaudeMains().count
        let blockers = running == 0
            ? ""
            : " — \(running) running instance\(running == 1 ? "" : "s") block the swap"
        return [Diagnostic(
            severity: .warning,
            title: "Claude \(staged.stagedVersion) staged but not applied\(blockers)",
            detail: "Use “Apply update to all accounts” to quit every account, swap, and reopen"
        )]
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

    /// A soft warning per launcher built by an older wrapper than the current one —
    /// it still runs, but a rebuild would refresh its script/Info.plist (e.g. to run
    /// native instead of under Rosetta). Separate from `launcherDiagnostic` so an
    /// otherwise-ok launcher is reported as both "ok" and "stale".
    private func staleLauncherDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        discovered.filter(\.isStale).map { launcher in
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
    private func managedConfigDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        // Nothing to manage: no clones and the broker never touched the default account.
        let defaultPath = configuration.defaultAccountUserDataPath
        let brokerRelevant = configuration.deepLinkBrokerEnabled
            || managedConfigWriter.overlayExists(userDataPath: defaultPath)
        guard !discovered.isEmpty || brokerRelevant else { return [] }

        if managedConfigWriter.mdmPresent {
            let path = managedConfigWriter.presentManagedPreferencesURL?.path
                ?? CoreConstants.claudeManagedPreferencesPaths.first ?? ""
            return [Diagnostic(
                severity: .ok,
                title: "Claude is MDM-managed — per-profile auto-update control is handled by managed preferences",
                detail: PathUtils.abbreviatingHome(path)
            )]
        }
        return cloneOverlayDiagnostics(discovered) + defaultAccountOverlayDiagnostics(defaultPath)
    }

    /// Warn once per distinct clone user-data-dir whose overlay does not match what the
    /// current broker setting expects (updater not disabled, or — with the broker on —
    /// deep-link registration not suppressed).
    private func cloneOverlayDiagnostics(_ discovered: [LauncherBundle.Discovered]) -> [Diagnostic] {
        let expected = ProfileManagedConfig.clone(
            deepLinkBrokerEnabled: configuration.deepLinkBrokerEnabled
        )
        var seen = Set<String>()
        return discovered.compactMap { launcher in
            let profilePath = launcher.marker.profile
            guard seen.insert(profilePath).inserted,
                  !managedConfigWriter.isSatisfied(expected, userDataPath: profilePath)
            else { return nil }
            return Diagnostic(
                severity: .warning,
                title: "\(launcher.displayName): managed config not applied — reopen Claude Manager or rebuild",
                detail: PathUtils.abbreviatingHome(profilePath)
            )
        }
    }

    /// The default account's deep-link-broker overlay state — the only visibility into the
    /// safety-critical write, since its reconcile is best-effort. Broker on → the default
    /// must suppress deep-link registration; broker off → that suppression must have been
    /// *restored* (key removed). A silent failure of either leaves the default account's
    /// link handling wrong.
    private func defaultAccountOverlayDiagnostics(_ defaultPath: String) -> [Diagnostic] {
        if configuration.deepLinkBrokerEnabled {
            guard !managedConfigWriter.isSatisfied(
                .defaultAccount(deepLinkBrokerEnabled: true), userDataPath: defaultPath
            ) else { return [] }
            return [Diagnostic(
                severity: .warning,
                title: "Default account: claude:// broker not applied — reopen Claude Manager",
                detail: PathUtils.abbreviatingHome(defaultPath)
            )]
        }
        // Broker off: warn only if the suppression key is still present (restore incomplete).
        guard managedConfigWriter.isSatisfied(
            ProfileManagedConfig(disableDeepLinkRegistration: true), userDataPath: defaultPath
        ) else { return [] }
        return [Diagnostic(
            severity: .warning,
            title: "Default account: deep-link handling not restored — toggle the broker off again",
            detail: PathUtils.abbreviatingHome(defaultPath)
        )]
    }

    private func orphanProfileDiagnostics(known: Set<String>) -> [Diagnostic] {
        let dir = configuration.defaultProfilesDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .sorted { $0.path < $1.path }
            .filter { entry in
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
                    && !known.contains(entry.path)
                    && !entry.lastPathComponent.hasPrefix("_")
                    // `<name>-3p` is our managed-config tier, not a user profile dir.
                    && !entry.lastPathComponent.hasSuffix("-3p")
            }
            .map {
                Diagnostic(
                    severity: .warning,
                    title: "Orphan profile (no launcher)",
                    detail: PathUtils.abbreviatingHome($0.path)
                )
            }
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

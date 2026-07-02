import Foundation

/// Health check over the real app, every managed launcher, orphaned profile dirs,
/// and duplicate running instances. Produces a flat, ordered list of diagnostics.
public struct Doctor {
    let realClaude: RealClaude?
    let configuration: ProfileStoreConfiguration
    let bundle: LauncherBundle
    let processProbe: ProcessProbe
    let fileManager: FileManager

    public init(
        realClaude: RealClaude?,
        configuration: ProfileStoreConfiguration,
        bundle: LauncherBundle = LauncherBundle(),
        processProbe: ProcessProbe,
        fileManager: FileManager = .default
    ) {
        self.realClaude = realClaude
        self.configuration = configuration
        self.bundle = bundle
        self.processProbe = processProbe
        self.fileManager = fileManager
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

        diagnostics.append(contentsOf: orphanProfileDiagnostics(known: knownProfiles))
        diagnostics.append(contentsOf: duplicateInstanceDiagnostics())
        return diagnostics
    }

    // MARK: - Individual checks

    private func realClaudeDiagnostic() -> Diagnostic {
        guard let realClaude, realClaude.binaryExists(fileManager: fileManager) else {
            return Diagnostic(
                severity: .error,
                title: "Real Claude.app is missing",
                detail: realClaude.map { PathUtils.abbreviatingHome($0.appURL.path) }
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

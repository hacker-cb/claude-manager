import Foundation
import Testing
@testable import ClaudeManagerCore

struct DoctorTests {
    let fm = FileManager.default

    struct Scene {
        let root: URL
        let installDir: URL
        let profilesDir: URL
        let real: RealClaude
    }

    func makeScene() throws -> Scene {
        let root = try Fixture.makeTempDir()
        let installDir = root.appendingPathComponent("apps")
        let profilesDir = root.appendingPathComponent("profiles")
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let real = try Fixture.makeFakeRealApp(in: root, iconData: Data("x".utf8))
        return Scene(root: root, installDir: installDir, profilesDir: profilesDir, real: real)
    }

    func buildLauncher(
        in scene: Scene,
        name: String,
        profileDir: URL?,
        realBinaryPath: String? = nil
    ) throws {
        let display = Profile.defaultDisplayName(for: name)
        let profile = Profile(
            name: name,
            displayName: display,
            label: "L",
            color: .named("blue"),
            profilePath: (profileDir ?? scene.profilesDir.appendingPathComponent(name)).path,
            bundleID: Profile.defaultBundleID(for: name),
            appPath: scene.installDir.appendingPathComponent("\(display).app").path
        )
        try LauncherBundle().build(
            profile: profile,
            realBinaryPath: realBinaryPath ?? scene.real.binaryURL.path,
            icnsData: Data("i".utf8)
        )
    }

    func doctor(_ scene: Scene, runner: CommandRunner) -> [Diagnostic] {
        Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir
            ),
            processProbe: ProcessProbe(runner: runner),
            // Hermetic MDM state: point at an absent path so tests never depend on the
            // host machine's real managed-preferences.
            managedConfigWriter: ManagedConfigWriter(
                fileManager: fm,
                managedPreferencesURLs: [scene.root.appendingPathComponent("no-mdm.plist")]
            )
        ).run()
    }

    @Test
    func reportsHealthyLauncherAndRealApp() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags.allHealthy)
        #expect(diags.contains { $0.title.contains("Real Claude.app v9.9.9") })
        #expect(diags.contains { $0.severity == .ok && $0.title.contains("Claude WORK: ok") })
    }

    @Test
    func reportsMissingRealApp() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let diags = Doctor(
            realClaude: nil,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir, defaultProfilesDirectory: scene.profilesDir
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub))
        ).run()
        #expect(diags.contains { $0.severity == .error && $0.title.contains("Real Claude.app is missing") })
    }

    @Test
    func reportsRealAppWithoutExecutable() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The bundle "resolves" but its executable is absent (a broken/partial update).
        let broken = RealClaude(appURL: scene.root.appendingPathComponent("Missing.app"))
        let diags = Doctor(
            realClaude: broken,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir, defaultProfilesDirectory: scene.profilesDir
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub))
        ).run()
        #expect(diags.contains { $0.severity == .error && $0.title.contains("no executable") })
    }

    @Test
    func warnsWhenProfileDirMissing() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try buildLauncher(in: scene, name: "work", profileDir: nil) // dir not created

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags.contains { $0.severity == .warning && $0.title.contains("profile dir missing") })
    }

    @Test
    func errorsWhenScriptDoesNotPointAtRealBinary() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try buildLauncher(
            in: scene,
            name: "work",
            profileDir: scene.profilesDir.appendingPathComponent("work"),
            realBinaryPath: "/somewhere/else/Claude"
        )
        try fm.createDirectory(
            at: scene.profilesDir.appendingPathComponent("work"),
            withIntermediateDirectories: true
        )

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.allHealthy)
        #expect(diags
            .contains { $0.severity == .error && $0.title.contains("does not point at the real binary") })
    }

    @Test
    func warnsOnOrphanProfile() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try fm.createDirectory(
            at: scene.profilesDir.appendingPathComponent("ghost"),
            withIntermediateDirectories: true
        )
        // `_`-prefixed dirs are scratch and must be ignored.
        try fm.createDirectory(
            at: scene.profilesDir.appendingPathComponent("_scratch"),
            withIntermediateDirectories: true
        )

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags
            .contains { $0.title == "Orphan profile (no launcher)" && ($0.detail?.contains("ghost") ?? false)
            })
        #expect(!diags.contains { $0.detail?.contains("_scratch") ?? false })
    }

    @Test
    func notesWhenClaudeIsMDMManaged() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)
        let mdm = scene.root.appendingPathComponent("com.anthropic.claudefordesktop.plist")
        try Data("<plist/>".utf8).write(to: mdm)

        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir, defaultProfilesDirectory: scene.profilesDir
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: [mdm])
        ).run()
        // An informational (.ok) note — not a standing warning — replaces the per-clone
        // warnings (the managed tier owns the policy).
        #expect(diags.contains { $0.severity == .ok && $0.title.contains("MDM-managed") })
        #expect(!diags.contains { $0.title.contains("auto-update not disabled") })
        #expect(diags.allHealthy)
    }

    @Test
    func noMDMNoteWhenNoLaunchers() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let mdm = scene.root.appendingPathComponent("com.anthropic.claudefordesktop.plist")
        try Data("<plist/>".utf8).write(to: mdm)
        // MDM present but zero clones → no note at all (nothing to override).
        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir, defaultProfilesDirectory: scene.profilesDir
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: [mdm])
        ).run()
        #expect(!diags.contains { $0.title.contains("MDM-managed") })
    }

    @Test
    func overlayTierNotFlaggedAsOrphanProfile() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)
        // The clone's `-3p` overlay tier lives in the profiles dir — not a user profile.
        try fm.createDirectory(
            at: scene.profilesDir.appendingPathComponent("work-3p"),
            withIntermediateDirectories: true
        )

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains {
            $0.title == "Orphan profile (no launcher)" && ($0.detail?.contains("work-3p") ?? false)
        })
    }

    @Test
    func warnsWhenCloneOverlayMissing() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("auto-update not disabled")
        })
    }

    @Test
    func noOverlayWarningWhenSatisfied() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)
        try ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("no-mdm.plist")]
        ).reconcile(.clone, userDataPath: profileDir.path)

        let diags = doctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains { $0.title.contains("auto-update not disabled") })
    }

    @Test
    func warnsOnDuplicateInstances() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let runner = RecordingCommandRunner { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(exitCode: 0, standardOutput: """
                  101     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/data/dup
                  202     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/data/dup
                """, standardError: "")
            }
            return idleStub(executable, args)
        }
        let diags = doctor(scene, runner: runner)
        #expect(diags.contains {
            $0.severity == .warning
                && $0.title == "Duplicate instances on one profile"
                && ($0.detail?.contains("101, 202") ?? false)
        })
    }

    @Test
    func warnsWhenRunningInstanceIsBehindClaude() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)

        // A live instance on 9.9.8 (from its child's telemetry) while the app on disk
        // is 9.9.9 (makeFakeRealApp) — the launcher should be told to restart.
        let runner = RecordingCommandRunner { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(exitCode: 0, standardOutput: """
                  501     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(profileDir.path)
                  502   501 /Applications/Claude.app/Contents/MacOS/Claude Helper --type=renderer --desktop-telemetry-config={"appVersion":"9.9.8"}
                """, standardError: "")
            }
            return idleStub(executable, args)
        }
        let diags = doctor(scene, runner: runner)
        #expect(diags.contains {
            $0.severity == .warning
                && $0.title.contains("Claude WORK: running v9.9.8")
                && $0.title.contains("restart to update")
        })
    }

    @Test
    func noSkewWarningWhenInstanceMatchesDiskVersion() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let profileDir = scene.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildLauncher(in: scene, name: "work", profileDir: profileDir)

        // Instance already on 9.9.9 — no restart nudge; and an unmanaged instance on an
        // old version (a profile no launcher owns) must never be flagged either.
        let runner = RecordingCommandRunner { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(exitCode: 0, standardOutput: """
                  501     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(profileDir.path)
                  502   501 /Applications/Claude.app/Contents/MacOS/Claude Helper --type=renderer --desktop-telemetry-config={"appVersion":"9.9.9"}
                  601     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/some/unmanaged
                  602   601 /Applications/Claude.app/Contents/MacOS/Claude Helper --type=renderer --desktop-telemetry-config={"appVersion":"1.0.0"}
                """, standardError: "")
            }
            return idleStub(executable, args)
        }
        let diags = doctor(scene, runner: runner)
        #expect(!diags.contains { $0.title.contains("restart to update") })
    }
}

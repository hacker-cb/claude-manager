import Foundation
import Testing
@testable import ClaudeManagerCore

/// Doctor checks on the **default profile**'s overlay — its own file/suite so neither it nor
/// `DoctorTests` exceeds the type-body / file-length budgets. Reuses the file-level Doctor
/// fixture (`makeDoctorScene`, `runDoctor`) from `DoctorTests.swift`.
struct DoctorDefaultProfileTests {
    let fm = FileManager.default

    @Test
    func warnsWhenDefaultProfileIsSuppressed() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The default profile should never carry disableDeepLinkRegistration (guard-based).
        // A leftover key (e.g. from an earlier build) must be flagged.
        try seedRawOverlay(
            ["disableDeepLinkRegistration": true],
            userDataPath: scene.defaultProfilePath,
            fileManager: fm
        )

        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir,
                managedPreferencesURLs: scene.noMDM,
                defaultProfileUserDataPath: scene.defaultProfilePath,
                shipItStatePath: scene.shipItStatePath
            ),
            bundle: LauncherBundle(runner: RecordingCommandRunner(handler: idleStub)),
            codeSigner: CodeSigner(runner: RecordingCommandRunner(handler: idleStub)),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
        ).run(managingUpdates: false)
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("deep-link registration is suppressed")
        })
    }

    @Test
    func warnsWhenDefaultProfileAutoUpdatesDisabled() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The default profile is the update leader — it must never carry disableAutoUpdates.
        // A stray key silently breaks the update model for every profile, so Doctor must warn.
        try ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
            .reconcile(
                ProfileManagedConfig(disableAutoUpdates: true),
                userDataPath: scene.defaultProfilePath
            )

        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir,
                managedPreferencesURLs: scene.noMDM,
                defaultProfileUserDataPath: scene.defaultProfilePath,
                shipItStatePath: scene.shipItStatePath
            ),
            bundle: LauncherBundle(runner: RecordingCommandRunner(handler: idleStub)),
            codeSigner: CodeSigner(runner: RecordingCommandRunner(handler: idleStub)),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
        ).run(managingUpdates: false)
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("auto-updates are disabled")
        })
    }

    @Test
    func noSuppressionWarningWhenDefaultProfileClean() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // Broker on (runDoctor's default), default profile never written → no false positive.
        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains { $0.title.contains("deep-link registration is suppressed") })
    }

    /// With Claude Manager doing the updating, the default profile's own updater must be
    /// off — left on, Claude stages builds of its own and force-restarts the profile every
    /// ~72 h to install one.
    @Test
    func warnsWhenTheDefaultProfileStillUpdatesItself() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // No overlay at all: Claude's own updater is on.
        #expect(overlayDiagnostics(scene, managingUpdates: true).contains {
            $0.severity == .warning && $0.title.contains("Claude's own updater is still on")
        })
    }

    /// The check reverses with who is in charge: the same state that is healthy above is a
    /// warning once the job has been handed back.
    @Test
    func warnsWhenTheUpdaterIsOffButClaudeIsSupposedToUpdateItself() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try seedRawOverlay(
            ["disableAutoUpdates": true], userDataPath: scene.defaultProfilePath, fileManager: fm
        )

        #expect(overlayDiagnostics(scene, managingUpdates: false).contains {
            $0.severity == .warning && $0.title.contains("auto-updates are disabled")
        })
    }

    /// The healthy configuration has to be silent, or the warning is just noise.
    @Test
    func staysQuietWhenTheUpdaterMatchesWhoIsInCharge() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try seedRawOverlay(
            ["disableAutoUpdates": true], userDataPath: scene.defaultProfilePath, fileManager: fm
        )

        let diags = overlayDiagnostics(scene, managingUpdates: true)
        #expect(!diags.contains {
            $0.title.contains("updater is still on") || $0.title.contains("auto-updates are disabled")
        })
    }

    private func overlayDiagnostics(
        _ scene: DoctorScene, managingUpdates: Bool
    ) -> [Diagnostic] {
        Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir,
                managedPreferencesURLs: scene.noMDM,
                defaultProfileUserDataPath: scene.defaultProfilePath,
                shipItStatePath: scene.shipItStatePath
            ),
            bundle: LauncherBundle(runner: RecordingCommandRunner(handler: idleStub)),
            codeSigner: CodeSigner(runner: RecordingCommandRunner(handler: idleStub)),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
        ).run(managingUpdates: managingUpdates)
    }
}

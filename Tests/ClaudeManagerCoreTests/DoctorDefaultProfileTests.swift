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
        ).run()
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
        ).run()
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
}

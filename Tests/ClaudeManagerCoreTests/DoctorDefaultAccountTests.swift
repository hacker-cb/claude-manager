import Foundation
import Testing
@testable import ClaudeManagerCore

/// Doctor checks on the **default account**'s overlay — its own file/suite so neither it nor
/// `DoctorTests` exceeds the type-body / file-length budgets. Reuses the file-level Doctor
/// fixture (`makeDoctorScene`, `runDoctor`) from `DoctorTests.swift`.
struct DoctorDefaultAccountTests {
    let fm = FileManager.default

    @Test
    func warnsWhenDefaultAccountIsSuppressed() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The default account should never carry disableDeepLinkRegistration (guard-based).
        // A leftover key (e.g. from an earlier build) must be flagged.
        try seedRawOverlay(
            ["disableDeepLinkRegistration": true],
            userDataPath: scene.defaultAccountPath,
            fileManager: fm
        )

        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir,
                managedPreferencesURLs: scene.noMDM,
                defaultAccountUserDataPath: scene.defaultAccountPath,
                shipItStatePath: scene.shipItStatePath
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
        ).run()
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("deep-link registration is suppressed")
        })
    }

    @Test
    func warnsWhenDefaultAccountAutoUpdatesDisabled() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The default account is the update leader — it must never carry disableAutoUpdates.
        // A stray key silently breaks the update model for every account, so Doctor must warn.
        try ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
            .reconcile(
                ProfileManagedConfig(disableAutoUpdates: true),
                userDataPath: scene.defaultAccountPath
            )

        let diags = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: scene.profilesDir,
                managedPreferencesURLs: scene.noMDM,
                defaultAccountUserDataPath: scene.defaultAccountPath,
                shipItStatePath: scene.shipItStatePath
            ),
            processProbe: ProcessProbe(runner: RecordingCommandRunner(handler: idleStub)),
            managedConfigWriter: ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: scene.noMDM)
        ).run()
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("auto-updates are disabled")
        })
    }

    @Test
    func noSuppressionWarningWhenDefaultAccountClean() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // Broker on (runDoctor's default), default account never written → no false positive.
        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains { $0.title.contains("deep-link registration is suppressed") })
    }
}

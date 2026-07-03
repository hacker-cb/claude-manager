import Foundation
import Testing
@testable import ClaudeManagerCore

/// Edge cases of the mutating store entry points — the create/edit/remove/stop
/// paths a user actually hits. Separate file/suite so no single test file grows
/// past the length cap; shares `makeStoreEnv` with the other ProfileStore suites.
struct ProfileStoreMutationEdgeTests {
    let fm = FileManager.default

    @Test
    func addWithForceRebuildsExistingLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        // A second add without force is refused; with force it rebuilds in place.
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work")))
        }
        let rebuilt = try env.store.add(AddProfileRequest(name: env.name("work"), force: true))
        #expect(fm.fileExists(atPath: rebuilt.profile.appPath))
        // A forced rebuild restarts the Dock (its icon may be cached); a fresh add didn't.
        #expect(!env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    @Test
    func updateRejectsRenameToExistingLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let aa = try env.store.add(AddProfileRequest(name: env.name("aa"))).profile
        _ = try env.store.add(AddProfileRequest(name: env.name("bb"))).profile
        var renamed = aa
        renamed.displayName = env.display("bb") // collides with bb's launcher
        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(original: aa, to: renamed)
        }
    }

    @Test
    func updateRejectsInvalidBundleID() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let work = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var bad = work
        bad.bundleID = "no dots here"
        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(original: work, to: bad)
        }
    }

    @Test
    func updateRefusedWhileProfileRunning() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let work = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Now report the profile as running; an edit must be refused before any write.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        var edited = work
        edited.label = "ZZ"
        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(original: work, to: edited)
        }
    }

    @Test
    func removePurgeWithMissingDataKeepsPurgedFalse() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("ghost"))
        }
        // A launcher whose profile dir was never created (e.g. never launched).
        let profile = env.store.draft(name: env.name("ghost"))
        try LauncherBundle().build(
            profile: profile,
            realBinaryPath: env.real.binaryURL.path,
            icnsData: Data("i".utf8)
        )
        #expect(!fm.fileExists(atPath: profile.profilePath))
        let result = try env.store.remove(profile, purgeProfile: true)
        #expect(!result.purgedProfileData) // nothing to purge
        #expect(!fm.fileExists(atPath: profile.appPath)) // launcher still trashed
    }

    @Test
    func stopSendsSIGKILLWhenForcedAndSIGTERMOtherwise() async throws {
        for (force, expected): (Bool, Int32) in [(true, SIGKILL), (false, SIGTERM)] {
            let counter = CallCounter()
            let env = try makeStoreEnv(stub: { executable, args in
                if executable == CoreConstants.pgrepPath {
                    // Running on the first (guard) probe, gone right after the signal.
                    let out = counter.next() == 1 ? "555\n" : ""
                    return CommandOutput(
                        exitCode: out.isEmpty ? 1 : 0, standardOutput: out, standardError: ""
                    )
                }
                return idleStub(executable, args)
            })
            defer { try? fm.removeItem(at: env.root) }
            let recorder = SignalRecorder()
            let store = ProfileStore(
                realClaude: env.real,
                configuration: ProfileStoreConfiguration(
                    installDirectory: env.installDir, defaultProfilesDirectory: env.profilesDir
                ),
                runner: env.runner,
                signalSender: { _, signal in recorder.record(signal) }
            )
            let profile = store.draft(name: env.name("work"))
            _ = await store.stop(profile, force: force, pollInterval: 0.01, maxPolls: 5)
            #expect(recorder.signals == [expected])
        }
    }
}

import Foundation
import Testing
@testable import ClaudeManagerCore

/// `remove` — trashing a launcher and deciding what happens to the data behind it.
/// Separate file/suite so no single test file grows past the length cap, mirroring
/// `ProfileStore+Remove.swift`; shares `makeStoreEnv` with the other ProfileStore suites.
struct ProfileStoreRemoveTests {
    let fm = FileManager.default

    @Test
    func removeTrashesLauncherAndPurgesData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: true)

        #expect(!fm.fileExists(atPath: profile.appPath))
        #expect(!fm.fileExists(atPath: profile.profilePath))
        #expect(result.profileData == .purged)
        // A removal that did exactly what was asked says nothing.
        #expect(result.profileData.notice(forRemovalOf: profile.displayName) == nil)
    }

    @Test
    func removeKeepsDataByDefault() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: false)
        #expect(result.profileData == .notRequested)
        #expect(result.profileData.notice(forRemovalOf: profile.displayName) == nil)
        #expect(fm.fileExists(atPath: profile.profilePath))
    }

    @Test
    func removeKeepsDataSharedByAnotherLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"), profilePath: shared)).profile
        let second = try env.store.add(AddProfileRequest(name: env.name("bb"), profilePath: shared)).profile

        let result = try env.store.remove(first, purgeProfile: true)
        // The second launcher still points at the shared dir, so its data is kept.
        #expect(result.profileData == .keptSharedWith(launchers: [second.displayName]))
        #expect(fm.fileExists(atPath: shared))
        // The refusal is correct; being quiet about it is not. The user asked to delete a
        // login and it is still on disk, so the notice has to name what is holding it.
        let notice = try #require(result.profileData.notice(forRemovalOf: first.displayName))
        #expect(notice.contains(first.displayName))
        #expect(notice.contains(second.displayName))
    }

    @Test
    func purgeSpares3pSiblingThatIsAnotherLaunchersData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("sibling"))
        }
        // Pathological but reachable: launcher B's user-data dir is literally launcher A's
        // `-3p` overlay path. Purging A must delete A's data + overlay but spare B's data.
        let workPath = env.profilesDir.appendingPathComponent("work").path
        let siblingPath = workPath + "-3p"
        let work = try env.store
            .add(AddProfileRequest(name: env.name("work"), profilePath: workPath)).profile
        _ = try env.store
            .add(AddProfileRequest(name: env.name("sibling"), profilePath: siblingPath)).profile
        try fm.createDirectory(atPath: siblingPath, withIntermediateDirectories: true, attributes: nil)
        let keep = URL(fileURLWithPath: siblingPath).appendingPathComponent("data")
        try Data("keep".utf8).write(to: keep)

        let result = try env.store.remove(work, purgeProfile: true)

        // B's data dir (== A's `-3p` path) belongs to another launcher, so it is spared.
        #expect(fm.fileExists(atPath: siblingPath))
        #expect(fm.fileExists(atPath: keep.path))
        // B points at A's *overlay* path, not at A's data dir, so it does not hold A's data
        // back: this is a purge that went through, not a refusal.
        #expect(result.profileData == .purged)
    }

    @Test
    func removeThrowsWhenLauncherMissing() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A profile whose launcher was never built → consistent domain error.
        let ghost = env.store.draft(name: env.name("ghost"))
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(ghost, purgeProfile: false)
        }
    }

    @Test
    func removeRejectsRunning() throws {
        let env = try makeStoreEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "999\n", standardError: "")
            }
            return idleStub(executable, args)
        })
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = env.store.draft(name: env.name("work"))
        try LauncherBundle(runner: stubbedSigningRunner()).build(
            profile: profile,
            realBinaryPath: env.real.binaryURL.path,
            icnsData: Data("i".utf8)
        )
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(profile, purgeProfile: false)
        }
    }
}

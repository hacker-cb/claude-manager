import Foundation
import Testing
@testable import ClaudeManagerCore

/// The managed-config overlay reconciled by `ProfileStore` on create / rebuild /
/// reconcile-all, and removed when a profile's data is purged.
struct ProfileStoreManagedConfigTests {
    let fm = FileManager.default

    /// A writer over the same defaults `ProfileStore` uses (real-system MDM path,
    /// absent on CI), for asserting the store's on-disk result.
    let probe = ManagedConfigWriter()

    func tier(_ profile: Profile) -> URL {
        ManagedConfigWriter.localTierURL(forUserDataPath: profile.profilePath)
    }

    @Test
    func addWritesUpdaterDisablingOverlay() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(probe.isSatisfied(.clone, userDataPath: profile.profilePath))
    }

    @Test
    func rebuildReSeedsOverlay() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Simulate an install predating the overlay (or a wiped tier).
        try fm.removeItem(at: tier(profile))
        #expect(!probe.isSatisfied(.clone, userDataPath: profile.profilePath))

        try env.store.rebuild(profile, restartDock: false)
        #expect(probe.isSatisfied(.clone, userDataPath: profile.profilePath))
    }

    @Test
    func reconcileAllWritesForEveryProfile() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let work = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let home = try env.store.add(AddProfileRequest(name: env.name("home"))).profile
        try fm.removeItem(at: tier(work))
        try fm.removeItem(at: tier(home))

        let failed = env.store.reconcileAllManagedConfigs()
        #expect(failed.isEmpty)
        #expect(probe.isSatisfied(.clone, userDataPath: work.profilePath))
        #expect(probe.isSatisfied(.clone, userDataPath: home.profilePath))
    }

    @Test
    func removePurgeDeletesOverlayTier() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(fm.fileExists(atPath: tier(profile).path))

        let result = try env.store.remove(profile, purgeProfile: true)
        #expect(result.purgedProfileData)
        #expect(!fm.fileExists(atPath: tier(profile).path))
    }

    @Test
    func removeKeepingDataKeepsOverlayTier() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        _ = try env.store.remove(profile, purgeProfile: false)
        // Data kept → overlay kept (a re-add reuses both).
        #expect(fm.fileExists(atPath: tier(profile).path))
    }
}

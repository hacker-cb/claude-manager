import Foundation
import Testing
@testable import ClaudeManagerCore

/// The managed-config overlay reconciled by `ProfileStore` on create / rebuild /
/// reconcile-all, and removed when a profile's data is purged.
struct ProfileStoreManagedConfigTests {
    let fm = FileManager.default

    func tier(_ profile: Profile) -> URL {
        ManagedConfigWriter.localTierURL(forUserDataPath: profile.profilePath)
    }

    /// A probe wired to the same hermetic (absent) MDM paths the store uses, so it reads
    /// the on-disk overlay rather than short-circuiting on the host's real MDM state.
    func probe(_ env: StoreEnv) -> ManagedConfigWriter {
        ManagedConfigWriter(managedPreferencesURLs: env.managedPreferencesURLs)
    }

    @Test
    func addWritesUpdaterDisablingOverlay() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(probe(env).isSatisfied(.clone(), userDataPath: profile.profilePath))
    }

    @Test
    func rebuildReSeedsOverlay() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Simulate an install predating the overlay (or a wiped tier).
        try fm.removeItem(at: tier(profile))
        #expect(!probe(env).isSatisfied(.clone(), userDataPath: profile.profilePath))

        try env.store.rebuild(profile, restartDock: false)
        #expect(probe(env).isSatisfied(.clone(), userDataPath: profile.profilePath))
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
        #expect(probe(env).isSatisfied(.clone(), userDataPath: work.profilePath))
        #expect(probe(env).isSatisfied(.clone(), userDataPath: home.profilePath))
    }

    @Test
    func updateReSeedsOverlay() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try fm.removeItem(at: tier(profile))

        _ = try env.store.update(original: profile, to: profile)
        #expect(probe(env).isSatisfied(.clone(), userDataPath: profile.profilePath))
    }

    @Test
    func removePurgeCleansOverlayWhenDataDirAlreadyGone() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Data dir deleted out of band, but the `-3p` overlay tier lingers.
        try fm.removeItem(at: profile.profileURL)
        #expect(fm.fileExists(atPath: tier(profile).path))

        _ = try env.store.remove(profile, purgeProfile: true)
        #expect(!fm.fileExists(atPath: tier(profile).path))
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

    // MARK: - Deep-link overlay hygiene

    @Test
    func cloneOverlayDisablesUpdaterWithoutTheDeepLinkKey() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        _ = env.store.reconcileAllManagedConfigs()

        // The clone disables its own updater...
        let overlay = try #require(rawOverlay(profile.profilePath))
        #expect(overlay["disableAutoUpdates"] as? Bool == true)
        // ...and never carries disableDeepLinkRegistration, which would make Claude drop the
        // deep links the broker forwards to it.
        #expect(overlay["disableDeepLinkRegistration"] == nil)
        // The default profile is never written — its handler is held by the guard.
        #expect(!probe(env).overlayExists(userDataPath: env.defaultProfileUserDataPath))
    }

    @Test
    func reconcileStripsStaleDeepLinkKeyFromAClone() throws {
        // An earlier build wrote disableDeepLinkRegistration into a clone; reconcile must
        // remove it — else Claude drops every forwarded non-auth deep link.
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try seedRawOverlay(
            ["disableAutoUpdates": true, "disableDeepLinkRegistration": true],
            userDataPath: profile.profilePath
        )
        #expect(rawOverlay(profile.profilePath)?["disableDeepLinkRegistration"] as? Bool == true)

        _ = try env.store.reconcileManagedConfig(for: profile)
        let overlay = try #require(rawOverlay(profile.profilePath))
        #expect(overlay["disableDeepLinkRegistration"] == nil)
        #expect(overlay["disableAutoUpdates"] as? Bool == true) // the key we own stays enforced
    }

    @Test
    func reconcileStripsStaleDeepLinkKeyFromTheDefaultProfile() throws {
        // Same cleanup for the default profile — its handler is held by the guard, never a key.
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try seedRawOverlay(
            ["disableDeepLinkRegistration": true],
            userDataPath: env.defaultProfileUserDataPath
        )
        _ = try env.store.reconcileDefaultProfileConfig()
        #expect(rawOverlay(env.defaultProfileUserDataPath)?["disableDeepLinkRegistration"] == nil)
    }
}

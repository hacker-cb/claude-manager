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

    // MARK: - Deep-link broker

    @Test
    func brokerOffLeavesDefaultAccountUntouched() throws {
        let env = try makeStoreEnv(deepLinkBrokerEnabled: false)
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        _ = env.store.reconcileAllManagedConfigs()
        // With the broker off, the default account gets no overlay at all.
        #expect(!probe(env).overlayExists(userDataPath: env.defaultAccountUserDataPath))
    }

    @Test
    func brokerOnWritesDeepLinkToCloneAndDefault() throws {
        let env = try makeStoreEnv(deepLinkBrokerEnabled: true)
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        _ = env.store.reconcileAllManagedConfigs()

        // The clone gets both keys; the default gets only the deep-link key (stays the
        // update leader).
        #expect(probe(env).isSatisfied(
            .clone(deepLinkBrokerEnabled: true), userDataPath: profile.profilePath
        ))
        #expect(probe(env).isSatisfied(
            .defaultAccount(deepLinkBrokerEnabled: true), userDataPath: env.defaultAccountUserDataPath
        ))
        #expect(!probe(env).isSatisfied(
            ProfileManagedConfig(disableAutoUpdates: true), userDataPath: env.defaultAccountUserDataPath
        ))
    }

    @Test
    func togglingBrokerOffRestoresDeepLinks() throws {
        // Enable the broker and write the default-account overlay...
        let env = try makeStoreEnv(deepLinkBrokerEnabled: true)
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.reconcileDefaultAccountConfig()
        #expect(probe(env).isSatisfied(
            .defaultAccount(deepLinkBrokerEnabled: true), userDataPath: env.defaultAccountUserDataPath
        ))

        // ...then a broker-off store over the same paths must remove the key (restore).
        let off = ProfileStore(
            realClaude: env.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: env.installDir,
                defaultProfilesDirectory: env.profilesDir,
                managedPreferencesURLs: env.managedPreferencesURLs,
                defaultAccountUserDataPath: env.defaultAccountUserDataPath,
                deepLinkBrokerEnabled: false
            ),
            runner: env.runner,
            signalSender: { _, _ in 0 }
        )
        _ = try off.reconcileDefaultAccountConfig()
        #expect(!probe(env).isSatisfied(
            .defaultAccount(deepLinkBrokerEnabled: true), userDataPath: env.defaultAccountUserDataPath
        ))
    }
}

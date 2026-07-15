import Testing
@testable import ClaudeManagerCore

struct ProfileManagedConfigTests {
    @Test
    func flatEntriesOmitFalseFlags() {
        #expect(ProfileManagedConfig().flatEntries.isEmpty)
        #expect(ProfileManagedConfig(disableAutoUpdates: true).flatEntries == ["disableAutoUpdates": true])
        let both = ProfileManagedConfig(disableAutoUpdates: true, disableDeepLinkRegistration: true)
        #expect(both.flatEntries == ["disableAutoUpdates": true, "disableDeepLinkRegistration": true])
    }

    @Test
    func managedKeysCoverEveryFlag() {
        // Every key flatEntries can emit must be in managedKeys, or a toggled-off flag
        // would never be cleaned up on reconcile.
        let all = ProfileManagedConfig(disableAutoUpdates: true, disableDeepLinkRegistration: true)
        #expect(Set(all.flatEntries.keys).isSubset(of: ProfileManagedConfig.managedKeys))
        #expect(ProfileManagedConfig.managedKeys == ["disableAutoUpdates", "disableDeepLinkRegistration"])
    }

    @Test
    func cloneAlwaysDisablesUpdaterDeepLinkFollowsBroker() {
        // A clone always disables its own updater; deep-link registration only when the
        // broker owns the handler.
        #expect(ProfileManagedConfig.clone(deepLinkBrokerEnabled: false).flatEntries
            == ["disableAutoUpdates": true])
        #expect(ProfileManagedConfig.clone(deepLinkBrokerEnabled: true).flatEntries
            == ["disableAutoUpdates": true, "disableDeepLinkRegistration": true])
    }

    @Test
    func defaultAccountKeepsUpdaterDeepLinkFollowsBroker() {
        // The default account stays the update leader; with the broker off it is the
        // empty overlay (so the default account is left untouched).
        #expect(ProfileManagedConfig.defaultAccount(deepLinkBrokerEnabled: false).flatEntries.isEmpty)
        #expect(ProfileManagedConfig.defaultAccount(deepLinkBrokerEnabled: true).flatEntries
            == ["disableDeepLinkRegistration": true])
    }
}

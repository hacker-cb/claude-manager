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
    func defaultAccountOverlayIsAlwaysEmpty() {
        // The default account is never written to — its handler is held by the guard, so
        // its overlay is always empty (nothing to orphan if Claude Manager is removed).
        #expect(ProfileManagedConfig.defaultAccount.flatEntries.isEmpty)
    }
}

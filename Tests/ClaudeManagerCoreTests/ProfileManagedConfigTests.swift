import Testing
@testable import ClaudeManagerCore

struct ProfileManagedConfigTests {
    @Test
    func flatEntriesOmitFalseFlags() {
        #expect(ProfileManagedConfig().flatEntries.isEmpty)
        #expect(ProfileManagedConfig(disableAutoUpdates: true).flatEntries == ["disableAutoUpdates": true])
    }

    @Test
    func managedKeysCoverEmittableFlagsPlusTheCleanupKey() {
        // Every key flatEntries can emit must be in managedKeys, or a toggled-off flag would
        // never be cleaned up on reconcile. managedKeys also retains disableDeepLinkRegistration
        // — no longer emitted, but still stripped from a clone an earlier build wrote it into.
        let emitted = ProfileManagedConfig(disableAutoUpdates: true).flatEntries
        #expect(Set(emitted.keys).isSubset(of: ProfileManagedConfig.managedKeys))
        #expect(ProfileManagedConfig.managedKeys == ["disableAutoUpdates", "disableDeepLinkRegistration"])
    }

    @Test
    func cloneDisablesUpdaterAndNeverWritesDeepLinkKey() {
        // A clone only disables its own updater; the claude:// handler is held by the guard,
        // never by a written disableDeepLinkRegistration (which would drop forwarded links).
        #expect(ProfileManagedConfig.clone().flatEntries == ["disableAutoUpdates": true])
    }

    /// The default profile's overlay now says who is updating Claude — and the empty case
    /// still has to be empty, so that handing the job back *removes* the key rather than
    /// writing `false` and leaving a fossil in an otherwise untouched profile.
    @Test
    func defaultProfileOverlayFollowsWhoIsUpdating() {
        #expect(ProfileManagedConfig.defaultProfile(managingUpdates: false).flatEntries.isEmpty)
        #expect(
            ProfileManagedConfig.defaultProfile(managingUpdates: true)
                .flatEntries["disableAutoUpdates"] == true
        )
    }

    /// Whichever way the updater key goes, the deep-link key is never written: that handler
    /// belongs to the event-driven guard, and this key makes Claude drop forwarded links.
    @Test(arguments: [true, false])
    func defaultProfileOverlayNeverTouchesDeepLinks(_ managingUpdates: Bool) {
        let entries = ProfileManagedConfig.defaultProfile(managingUpdates: managingUpdates).flatEntries
        #expect(entries[ProfileManagedConfig.disableDeepLinkRegistrationKey] == nil)
    }
}

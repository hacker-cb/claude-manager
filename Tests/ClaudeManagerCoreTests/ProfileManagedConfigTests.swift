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

    @Test
    func defaultAccountOverlayIsAlwaysEmpty() {
        // The default account is never written to — its handler is held by the guard, so
        // its overlay is always empty (nothing to orphan if Claude Manager is removed).
        #expect(ProfileManagedConfig.defaultAccount.flatEntries.isEmpty)
    }
}

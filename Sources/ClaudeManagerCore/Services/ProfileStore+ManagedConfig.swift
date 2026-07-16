import Foundation

/// Reconciling the Claude-Manager-owned managed-config overlay — the local config tier
/// (`<userData>-3p/configLibrary`) that disables a clone's Squirrel updater and, when
/// the `claude://` broker is on, suppresses deep-link registration on the **clones**. The
/// default account is kept overlay-free — its handler is held by the guard, never a
/// written key. Split out of `ProfileStore` to keep that file within budget.
public extension ProfileStore {
    /// Writer for the CM-owned per-profile overlay. A plain value over this store's
    /// `fileManager`; MDM detection uses the configuration's managed-preferences paths.
    var managedConfigWriter: ManagedConfigWriter {
        ManagedConfigWriter(
            fileManager: fileManager,
            managedPreferencesURLs: configuration.managedPreferencesURLs
        )
    }

    /// The overlay a cloned profile should hold, given the current broker setting.
    var cloneOverlay: ProfileManagedConfig {
        .clone(deepLinkBrokerEnabled: configuration.deepLinkBrokerEnabled)
    }

    /// Reconcile the overlay for one clone: pre-seed its local config tier so Claude's
    /// updater is disabled (and, with the broker on, its deep-link registration) on the
    /// clone's next launch. No-op when Claude is MDM-managed. Best-effort at the create /
    /// rebuild call sites (never blocks the primary operation); exposed as throwing so
    /// the startup reconcile and tests can observe failures.
    @discardableResult
    func reconcileManagedConfig(for profile: Profile) throws -> ManagedConfigWriter.Outcome {
        try managedConfigWriter.reconcile(cloneOverlay, userDataPath: profile.profilePath)
    }

    /// Keep the **default account** free of any CM-written overlay: its `claude://` handler
    /// is held by the guard, never by a written key. This reconciles the *empty*
    /// default-account overlay, which removes a `disableDeepLinkRegistration` left by an
    /// earlier build without ever materializing a new file in the untouched account.
    /// Returns the outcome, or `nil` when there was nothing to clean up.
    @discardableResult
    func reconcileDefaultAccountConfig() throws -> ManagedConfigWriter.Outcome? {
        try managedConfigWriter.reconcilePreservingUntouched(
            .defaultAccount, userDataPath: configuration.defaultAccountUserDataPath
        )
    }

    /// Reconcile overlays for every managed profile *and* the default account. The
    /// overlay is read only at launch, so writing under a live instance is harmless and
    /// takes effect on its next start. A single failure never aborts the batch; the
    /// profiles whose overlay could not be written are returned (`Doctor` independently
    /// surfaces a missing overlay, so callers may discard this).
    @discardableResult
    func reconcileAllManagedConfigs() -> [Profile] {
        var failed: [Profile] = []
        for managed in list() {
            do {
                _ = try reconcileManagedConfig(for: managed.profile)
            } catch {
                failed.append(managed.profile)
            }
        }
        try? reconcileDefaultAccountConfig()
        return failed
    }
}

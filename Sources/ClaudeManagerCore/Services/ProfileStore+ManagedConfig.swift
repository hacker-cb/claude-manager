import Foundation

/// Reconciling the Claude-Manager-owned managed-config overlay for cloned profiles —
/// the local config tier (`<userData>-3p/configLibrary`) that disables Claude's
/// Squirrel updater in a clone so only the default account checks / downloads / stages
/// updates. Split out of `ProfileStore` to keep that file within its length budget.
public extension ProfileStore {
    /// Writer for the CM-owned per-profile overlay. A plain value over this store's
    /// `fileManager`; MDM detection uses the system managed-preferences path.
    var managedConfigWriter: ManagedConfigWriter {
        ManagedConfigWriter(fileManager: fileManager)
    }

    /// Reconcile the overlay for one clone: pre-seed its local config tier so Claude's
    /// updater is disabled on the clone's next launch. No-op when Claude is MDM-managed.
    /// Best-effort at the create / rebuild call sites (never blocks the primary
    /// operation); exposed as throwing so the startup reconcile and tests can observe
    /// failures.
    @discardableResult
    func reconcileManagedConfig(for profile: Profile) throws -> ManagedConfigWriter.Outcome {
        try managedConfigWriter.reconcile(.clone, userDataPath: profile.profilePath)
    }

    /// Reconcile overlays for every managed profile, running or not — the overlay is
    /// read only at launch, so writing under a live clone is harmless and takes effect
    /// on its next start. A single profile's failure never aborts the batch; the
    /// profiles whose overlay could not be written are returned for surfacing.
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
        return failed
    }
}

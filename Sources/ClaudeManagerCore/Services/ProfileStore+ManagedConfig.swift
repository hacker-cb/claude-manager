import Foundation

/// Reconciling the Claude-Manager-owned managed-config overlay — the local config tier
/// (`<userData>-3p/configLibrary`) that disables a clone's Squirrel updater. The `claude://`
/// handler is held by the event-driven guard, not written here (on any profile) — so the
/// default *and* the clones stay free of `disableDeepLinkRegistration`, which would make
/// Claude drop the forwarded links the broker routes. Split out of `ProfileStore` to keep
/// that file within budget.
public extension ProfileStore {
    /// Writer for the CM-owned per-profile overlay. A plain value over this store's
    /// `fileManager`; MDM detection uses the configuration's managed-preferences paths.
    var managedConfigWriter: ManagedConfigWriter {
        ManagedConfigWriter(
            fileManager: fileManager,
            managedPreferencesURLs: configuration.managedPreferencesURLs
        )
    }

    /// The overlay a cloned profile should hold: just its Squirrel updater disabled.
    var cloneOverlay: ProfileManagedConfig {
        .clone()
    }

    /// Reconcile the overlay for one clone: pre-seed its local config tier so Claude's
    /// updater is disabled on the clone's next launch (and strip a stale
    /// `disableDeepLinkRegistration` an earlier build wrote). No-op when Claude is
    /// MDM-managed. Best-effort at the create / rebuild call sites (never blocks the primary
    /// operation); exposed as throwing so the startup reconcile and tests can observe failures.
    @discardableResult
    func reconcileManagedConfig(for profile: Profile) throws -> ManagedConfigWriter.Outcome {
        try managedConfigWriter.reconcile(cloneOverlay, userDataPath: profile.profilePath)
    }

    /// Bring the **default profile's** overlay in line with who is updating Claude.
    ///
    /// With `managingUpdates` true this switches the default profile's Squirrel updater off,
    /// the same as every clone's — which is what stops Claude force-restarting it every
    /// ~72 h to install a build of its own. With it false the overlay is empty again and
    /// Claude resumes the job, which is also how the key gets *removed* rather than left
    /// behind as a fossil.
    ///
    /// `claude://` is never written here either way; that handler belongs to the guard.
    /// Returns the outcome, or `nil` when there was nothing to change.
    @discardableResult
    func reconcileDefaultProfileConfig(managingUpdates: Bool) throws -> ManagedConfigWriter.Outcome? {
        try managedConfigWriter.reconcilePreservingUntouched(
            .defaultProfile(managingUpdates: managingUpdates),
            userDataPath: configuration.defaultProfileUserDataPath
        )
    }

    /// Reconcile overlays for every managed profile *and* the default profile. The
    /// overlay is read only at launch, so writing under a live instance is harmless and
    /// takes effect on its next start. A single failure never aborts the batch; the
    /// profiles whose overlay could not be written are returned (`Doctor` independently
    /// surfaces a missing overlay, so callers may discard this).
    @discardableResult
    func reconcileAllManagedConfigs(managingUpdates: Bool) -> [Profile] {
        var failed: [Profile] = []
        for managed in list() {
            do {
                _ = try reconcileManagedConfig(for: managed.profile)
            } catch {
                failed.append(managed.profile)
            }
        }
        try? reconcileDefaultProfileConfig(managingUpdates: managingUpdates)
        if managingUpdates { sweepSquirrelResidue() }
        return failed
    }

    /// Clear what Claude's own updater left behind, now that it is switched off.
    ///
    /// Switching `disableAutoUpdates` on stops Squirrel arming again but tidies nothing: the
    /// last armed job and the several hundred megabytes it points at both survive.
    ///
    /// Skipped whenever an installer might be running — `isRunning()`, which reads an
    /// unreadable probe as *running*, not `isConfirmedRunning()`, which reads it as not.
    /// A guard protecting a live install has to fail closed, and this one can afford to:
    /// the sweep is housekeeping, it runs again on the next reconcile, and waiting costs
    /// nothing but disk. Deleting a bundle out from under a live ShipIt costs the user their
    /// install.
    func sweepSquirrelResidue() {
        // An MDM-managed machine decides its own update policy through managed preferences,
        // which outrank the local overlay — so this app is not actually in charge there,
        // whatever its setting says, and clearing a job the MDM configuration armed would be
        // interfering with somebody else's update flow. The overlay writer already stands
        // down in that case; so does this.
        guard !managedConfigWriter.mdmPresent else {
            CoreLog.update.info("squirrel: MDM-managed, leaving its cache alone")
            return
        }
        guard !shipItProbe().isRunning() else {
            CoreLog.update.info("squirrel: an installer may be running, leaving its cache alone")
            return
        }
        let outcome = SquirrelResidue(
            statePath: configuration.shipItStatePath, fileManager: fileManager
        ).sweep()
        guard outcome.changedAnything else { return }
        CoreLog.update.info(
            """
            squirrel: swept \(outcome.removedStagedBundles.count, privacy: .public) staged bundle(s), \
            \(outcome.reclaimedBytes, privacy: .public) bytes
            """
        )
    }
}

import Foundation

/// Applying edits to an existing launcher. Split out of `ProfileStore` to keep that file
/// within its length budget.
public extension ProfileStore {
    /// Apply edits by rebuilding the launcher, trashing the old bundle on rename.
    ///
    /// Takes the profile and the edits separately, so a caller cannot substitute the
    /// profile's identity — its name and its user-data directory — under cover of an edit.
    /// `ProfileEdits` says what that used to allow and why the fields it does not carry are
    /// `let` on `Profile`.
    ///
    /// Applies while the profile is running, and reports that through `UpdateResult.liveRewrite`
    /// rather than refusing: the live process does not execute out of the bundle (see
    /// `LiveRewrite`), so what a running instance actually costs is a restart before the new
    /// name and badge reach it — not the right to make the edit. `remove` still refuses,
    /// because trashing the bundle a user might relaunch from is a different act.
    @discardableResult
    func update(_ original: Profile, applying edits: ProfileEdits) throws -> UpdateResult {
        try ensureRealBinaryPresent()
        // The profile has to be the launcher installed at its path, and it comes back spelling
        // its data directory the way that launcher records it — see `profileMatchingItsLauncher`.
        let original = try profileMatchingItsLauncher(original)
        // `name` is deliberately *not* validated here any more. It used to arrive from the
        // caller; it now comes from the profile, and `ProfileEdits` cannot carry one — so a
        // launcher whose hand-edited marker holds an invalid name would be locked out of every
        // future edit, with no field anywhere in the app able to correct it. The guard also
        // protected nothing: inside `update`, `name` reaches the marker and nothing else. What
        // derives a path is the display name, validated below.
        guard Profile.isValidDisplayName(edits.displayName) else {
            throw ClaudeManagerError.invalidDisplayName(edits.displayName)
        }
        guard Profile.isValidBundleID(edits.bundleID) else {
            throw ClaudeManagerError.invalidBundleID(edits.bundleID)
        }
        // The bundle path is re-derived from the install dir + validated display name rather
        // than carried in — the only injection-proof source for where the .app lands. The
        // identity fields come from `original`, which the check above matched against the
        // installed marker, so this is the only shape an edited profile can take.
        let updated = Profile(
            name: original.name,
            displayName: edits.displayName,
            label: edits.label,
            color: edits.color,
            profilePath: original.profilePath,
            bundleID: edits.bundleID,
            appPath: configuration.installDirectory
                .appendingPathComponent("\(edits.displayName).app").path
        )

        let renaming = updated.appPath != original.appPath
        if renaming, fileManager.fileExists(atPath: updated.appPath) {
            throw ClaudeManagerError.launcherAlreadyExists(path: updated.appPath)
        }
        // A launcher the user put out of sight stays out of sight across an edit. `build`
        // carries the flag itself, but only for a bundle it *replaces* — a rename installs at
        // a path that does not exist yet, so the flag has to come from the bundle being
        // retired, and only this side knows both paths.
        let wasHidden = (try? original.appURL.resourceValues(forKeys: [.isHiddenKey]))?
            .isHidden == true

        try ensureInstallDirectoryWritable()
        // The directory is the profile's own — an edit cannot point it elsewhere — so this
        // creates one only where the user deleted theirs by hand. Recorded all the same for
        // the rollback below, which must never delete a data directory it did not create;
        // `add` keeps the same guard on its failure path.
        let profileDirExisted = fileManager.fileExists(atPath: updated.profilePath)
        try fileManager.createDirectory(at: updated.profileURL, withIntermediateDirectories: true)

        let icns = try iconPipeline.makeBadgeICNS(
            realClaude: realClaude,
            label: updated.label,
            color: updated.color,
            style: configuration.badgeStyle
        )
        let iconChanged = try bundle.build(
            profile: updated, realBinaryPath: realClaude.binaryURL.path, icnsData: icns
        )

        // The rename's second half — retiring the old bundle. If it fails, the edit is undone
        // rather than left half-applied.
        //
        // Leaving the old bundle behind was the previous behaviour, and it is worse than it
        // looks: two launchers on one user-data dir is a state the app reads as *deliberate*
        // everywhere else, so nothing questions it. `list` scans the install directory, so the
        // stale bundle stays in the sidebar as an ordinary row; `runningPID` keys on the
        // profile dir, which both now share, so opening the profile lights up both rows with
        // the same pid and a Stop on the wrong one ends the live session; the sidebar
        // selection is the bundle path, so it goes on resolving to the *old* row after the
        // rename; and `liveRewrite` requires a single owning launcher, so the restart nudge
        // vanishes exactly when a running profile is renamed. Reporting all that is worse than
        // not creating it.
        //
        // `renaming` means the new path was empty (the guard above), so the rollback removes
        // only what this call wrote; the icon-cache registration and the managed-config
        // overlay happen below, so neither has run yet.
        if renaming, fileManager.fileExists(atPath: original.appPath) {
            do {
                _ = try bundle.moveToTrash(appURL: original.appURL)
            } catch {
                try rollBackRename(
                    original: original, updated: updated,
                    profileDirExisted: profileDirExisted, cause: error
                )
            }
        }

        if renaming, wasHidden {
            var url = updated.appURL
            var values = URLResourceValues()
            values.isHidden = true
            try? url.setResourceValues(values)
        }

        // Register so the new icon is picked up on next fetch — never flash the screen. A
        // pinned tile can be stale only for an in-place edit (or a rename onto a trashed
        // twin) that changed the icon; it is repainted by the app's opt-in refresh. A
        // fresh rename path has nothing cached.
        iconCache.register(appURL: updated.appURL)
        let dockRefreshPending =
            iconChanged && (!renaming || bundle.hasTrashedTwin(appURL: updated.appURL))
        // Seed the (possibly relocated) profile's overlay, as add/rebuild do.
        try? reconcileManagedConfig(for: updated)
        // The nudge names the *edited* profile, so it carries the updated value: after a
        // rename the old one names a bundle that is already in the Trash.
        // A running window shows the launcher's name and its badge, and nothing else this
        // write touches — so an edit that leaves both alone (a bundle-id change, or Save on
        // an unmodified form) has nothing for a restart to reveal.
        let presentationChanged = iconChanged || updated.displayName != original.displayName
        return UpdateResult(
            profile: updated,
            dockRefreshPending: dockRefreshPending,
            liveRewrite: liveRewrite(for: updated, presentationChanged: presentationChanged)
        )
    }
}

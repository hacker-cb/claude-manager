import Foundation

/// Undoing a rename whose second half failed. Split out of `ProfileStore` to keep that file
/// within its length budget.
extension ProfileStore {
    /// Called when a rename built its new bundle but could not retire the old one.
    ///
    /// Returns without throwing in exactly one case — the old bundle is already gone, so there
    /// is nothing left to retire and the rename may stand. Otherwise it restores the previous
    /// state and throws, so the caller never continues on a half-applied edit.
    ///
    /// **Why undo rather than report the leftover.** Two launchers on one user-data dir is a
    /// shape the app reads as *deliberate* everywhere else, so nothing questions it: `list`
    /// scans the install directory, leaving the stale bundle in the sidebar as an ordinary
    /// row; `runningPID` keys on the profile dir, which both now share, so opening the profile
    /// lights up both rows with the same pid and a Stop on the wrong one ends the live
    /// session; the sidebar selection is the bundle path, so it goes on resolving to the *old*
    /// row after the rename; and `liveRewrite` demands a single owning launcher, so the
    /// restart nudge disappears exactly when a running profile is renamed. Reporting all of
    /// that is worse than not creating it.
    func rollBackRename(
        original: Profile,
        updated: Profile,
        profileDirExisted: Bool,
        cause: Error
    ) throws {
        // The old bundle vanished between the existence check and the Trash attempt — Finder,
        // a second window, a cleanup script. Its removal is what the failed step was *for*, so
        // the rename stands. Rolling back here would delete the profile's only remaining
        // launcher and leave it with none at all, which is worse than either outcome this
        // function chooses between.
        guard fileManager.fileExists(atPath: original.appPath) else { return }

        let reason = Sentences.reason(cause)
        do {
            try fileManager.removeItem(at: updated.appURL)
        } catch {
            // Symmetric to the vanished-old-bundle check above: a removal that failed because
            // the new bundle is already gone *achieved* the rollback, so claiming two
            // launchers would be false and would send the user hunting for a second one that
            // does not exist. Only a bundle still on disk is that state.
            if fileManager.fileExists(atPath: updated.appPath) {
                throw ClaudeManagerError.renameLeftBothLaunchers(
                    oldPath: original.appPath, newPath: updated.appPath, reason: reason
                )
            }
        }
        // Only ever a directory this call created and left empty — never pre-existing profile
        // data. An edit cannot relocate the data dir (`ProfileEdits`), so the one way `update`
        // creates one is a profile whose directory the user deleted by hand; leaving that
        // behind would have Doctor report an orphan the user never made, under an error saying
        // nothing changed.
        if !profileDirExisted, !directoryHasContents(updated.profilePath) {
            try? fileManager.removeItem(at: updated.profileURL)
        }
        // The profile keeps its old launcher, so re-seed *that* one's overlay: the throw skips
        // the reconcile at the end of `update`, and a clone without its overlay lets Claude's
        // own updater run inside it. `rebuildAll` keeps the same guarantee on its failure path.
        try? reconcileManagedConfig(for: original)
        throw ClaudeManagerError.renameUndone(path: original.appPath, reason: reason)
    }
}

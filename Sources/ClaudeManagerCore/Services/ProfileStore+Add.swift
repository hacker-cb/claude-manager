import Foundation

/// The checks a *forced* create runs before it rebuilds over a bundle that is already there.
/// Split out of `ProfileStore` to keep that file, and `add` itself, within their length budgets.
extension ProfileStore {
    /// The profile a forced create may safely build with, or a throw naming why it may not.
    ///
    /// Called only when something is already installed at the drafted path. Without `force` that
    /// is simply a refusal; with it, "rebuild the launcher that is already here" — so what is
    /// here has to be one of ours, and it has to be this profile's.
    ///
    /// Both halves are load-bearing. `build` finishes with `replaceItemAt`, which *deletes* what
    /// it replaces: with no marker check, a forced create whose display name resolves onto a
    /// bundle we do not own destroys it outright, and the default install directory is the real
    /// Claude.app's own — a display name of "Claude" (the sheet's placeholder is "Claude NAME")
    /// wipes the user's Claude installation and every launcher's baked binary path with it. With
    /// no directory check, the rebuild repoints an existing launcher at another user-data dir and
    /// abandons the one holding its login and chat history.
    func profileForForcedRebuild(over profile: Profile, force: Bool) throws -> Profile {
        // Every refusal names the occupant as the **volume** stores it, for the same reason
        // `update` does: the display name is free text, `fileExists` folds case, and these
        // messages send the user to Finder. Creating "Claude WORK" beside an installed "Claude
        // Work" otherwise reports a collision with a path nothing on disk answers to. Only what
        // is *reported* changes — every check runs on the drafted path, which opens the same
        // bundle.
        let occupant = PathUtils.spellingOnDisk(profile.appPath) ?? profile.appPath
        guard force else {
            throw ClaudeManagerError.launcherAlreadyExists(path: occupant)
        }
        guard let installed = bundle.readMarker(at: profile.appURL) else {
            throw ClaudeManagerError.markerMissing(path: occupant)
        }
        guard PathUtils.sameDirectory(installed.marker.profile, profile.profilePath) else {
            throw ClaudeManagerError.launcherHoldsOtherProfileData(
                appPath: occupant,
                installed: installed.marker.profile,
                requested: profile.profilePath
            )
        }
        // The directory alone does not identify the launcher: two launchers may share one
        // profile directory, so a force with a *different* name and the sibling's display name
        // would pass the check above, replace that sibling, and write this name into its
        // marker — renaming a profile through a create.
        guard installed.marker.name == profile.name else {
            throw ClaudeManagerError.launcherBelongsToAnotherProfile(
                appPath: occupant,
                installedName: installed.marker.name,
                installedPath: installed.marker.profile
            )
        }
        // Adopt the marker's spelling of the directory the two agree on. `runningPID` greps for
        // the literal path, and the rebuilt marker records what is used here — so keeping the
        // requested spelling would miss a live instance launched under the recorded one, and
        // then leave `list` and `remove` blind to it afterwards.
        return Profile(
            name: profile.name,
            displayName: profile.displayName,
            label: profile.label,
            color: profile.color,
            profilePath: installed.marker.profile,
            bundleID: profile.bundleID,
            appPath: profile.appPath
        )
    }
}

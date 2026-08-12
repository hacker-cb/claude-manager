import Foundation

/// Outcome of removing a launcher.
public struct RemovalResult: Sendable {
    public let trashedAppURL: URL?
    public let profilePath: String
    /// What became of the user-data directory — including the reason it survived a removal
    /// that asked to delete it. See `ProfileDataOutcome`, which also carries the sentence the
    /// app shows for it.
    public let profileData: ProfileDataOutcome

    public init(trashedAppURL: URL?, profilePath: String, profileData: ProfileDataOutcome) {
        self.trashedAppURL = trashedAppURL
        self.profilePath = profilePath
        self.profileData = profileData
    }
}

/// Removing a launcher, and deciding what happens to the data behind it. Split out of
/// `ProfileStore` to keep that file within its length budget.
public extension ProfileStore {
    /// Move the launcher to Trash (and optionally delete the profile data).
    ///
    /// Unlike `update` and `rebuild`, this still refuses to run under a live instance: those
    /// two rewrite a bundle the running process does not execute out of, while this one takes
    /// the bundle away entirely — and, on request, the user-data directory the live instance
    /// has open.
    @discardableResult
    func remove(_ profile: Profile, purgeProfile: Bool) throws -> RemovalResult {
        guard fileManager.fileExists(atPath: profile.appPath) else {
            // Consistent domain error instead of a raw CocoaError from trashItem.
            throw ClaudeManagerError.launcherNotFound(name: profile.name)
        }
        if let pid = runningPID(for: profile) {
            throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
        }
        let trashed = try bundle.moveToTrash(appURL: profile.appURL)
        var profileData = ProfileDataOutcome.notRequested
        if purgeProfile {
            profileData = try purgeProfileData(for: profile)
        }
        return RemovalResult(
            trashedAppURL: trashed,
            profilePath: profile.profilePath,
            profileData: profileData
        )
    }

    /// Delete the user-data directory and its overlay sibling, reporting **why** when it
    /// survives instead. The reason is the whole point of the return value: the caller has
    /// just been asked to delete a login and a chat history, and "it is still there" without a
    /// cause is indistinguishable from the removal having silently failed.
    private func purgeProfileData(for profile: Profile) throws -> ProfileDataOutcome {
        // Never delete data another launcher still points at (the launcher we
        // just trashed is already gone from the scan).
        let survivors = bundle.scan(installDirectory: configuration.installDirectory)
        let sharing = survivors.filter { $0.marker.profile == profile.profilePath }
        guard sharing.isEmpty else {
            return .keptSharedWith(launchers: sharing.map(\.profile.displayName))
        }
        // Absent is a distinct answer from purged, and the difference is not academic: the
        // overlay sweep below runs either way, so "nothing was deleted" here means the data
        // dir was already gone — not that this step declined to touch it.
        var outcome = ProfileDataOutcome.alreadyGone
        if fileManager.fileExists(atPath: profile.profilePath) {
            try fileManager.removeItem(at: profile.profileURL)
            outcome = .purged
        }
        // Purge the `<profilePath>-3p` overlay sibling too — it is created
        // independently of the data dir, so remove it even if the data dir is
        // already gone (removeOverlay no-ops when absent). Guard a name collision:
        // if another launcher's user-data dir *is* that `-3p` path, it's that
        // profile's data, not our overlay — leave it alone.
        let overlayPath = ManagedConfigWriter
            .localTierURL(forUserDataPath: profile.profilePath).standardizedFileURL.path
        let overlayIsAnothersData = survivors.contains {
            URL(fileURLWithPath: $0.marker.profile).standardizedFileURL.path == overlayPath
        }
        if !overlayIsAnothersData {
            try? managedConfigWriter.removeOverlay(userDataPath: profile.profilePath)
        }
        return outcome
    }
}

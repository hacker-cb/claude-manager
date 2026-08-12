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
        return RemovalResult(
            trashedAppURL: trashed,
            profilePath: profile.profilePath,
            profileData: purgeProfile ? purgeProfileData(for: profile) : .notRequested
        )
    }

    /// Delete the user-data directory and its overlay sibling, reporting **why** when it
    /// survives instead. The reason is the whole point of the return value: the caller has
    /// just been asked to delete a login and a chat history, and "it is still there" without a
    /// cause is indistinguishable from the removal having silently failed.
    ///
    /// Nothing throws out of here, deliberately. The launcher is in the Trash by the time this
    /// runs, so a `removeItem` failure raised as an error reports the *whole* removal as
    /// failed while half of it already happened — and the half that did not is the half
    /// holding the credentials. It comes back as `purgeFailed` instead, carrying the reason.
    private func purgeProfileData(for profile: Profile) -> ProfileDataOutcome {
        // Never delete data another launcher still points at (the launcher we
        // just trashed is already gone from the scan).
        let survivors = bundle.scan(installDirectory: configuration.installDirectory)
        let sharing = survivors.filter {
            Self.directoriesOverlap($0.marker.profile, profile.profilePath)
        }
        // Existence first, so a refusal is only reported where there is something to refuse
        // over: with the directory already gone, "your login was kept" names credentials that
        // are not there and sends the user to remove a launcher for nothing.
        guard fileManager.fileExists(atPath: profile.profilePath) else {
            // The overlay is swept even here — it is created independently of the data dir —
            // but not when the path is shared, where it is the survivor's overlay too.
            if sharing.isEmpty { sweepOverlay(for: profile, survivors: survivors) }
            return .alreadyGone
        }
        guard sharing.isEmpty else {
            return .keptSharedWith(launchers: sharing.map(\.profile.displayName))
        }
        do {
            try fileManager.removeItem(at: profile.profileURL)
        } catch {
            // The overlay stays: this profile's data is still on disk, and the overlay is what
            // keeps Claude's own updater out of it.
            return .purgeFailed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        sweepOverlay(for: profile, survivors: survivors)
        return .purged
    }

    /// Remove the `<profilePath>-3p` overlay sibling. Guards a name collision: if another
    /// launcher's user-data dir *is* that `-3p` path, it's that profile's data, not our
    /// overlay — leave it alone. Best-effort (`removeOverlay` no-ops when absent).
    private func sweepOverlay(for profile: Profile, survivors: [LauncherBundle.Discovered]) {
        let overlayPath = ManagedConfigWriter
            .localTierURL(forUserDataPath: profile.profilePath).standardizedFileURL.path
        let overlayIsAnothersData = survivors.contains {
            URL(fileURLWithPath: $0.marker.profile).standardizedFileURL.path == overlayPath
        }
        if !overlayIsAnothersData {
            try? managedConfigWriter.removeOverlay(userDataPath: profile.profilePath)
        }
    }

    /// Whether deleting one of these directories would take the other with it — the same path,
    /// or one nested inside the other.
    ///
    /// Raw string equality is not enough on either count. The profile path is free text in the
    /// editor and only normalized (`PathUtils.absolutePath`), so one launcher's data can sit
    /// *inside* another's: `removeItem` on the outer one is recursive and takes the inner
    /// profile's Anthropic token and chat history with it, silently, since a scan filtered on
    /// equality reports nobody sharing. Two spellings of one directory miss each other the
    /// same way, which is why `sweepOverlay`'s own guard already standardizes both sides.
    ///
    /// Compared by path *component*, never by string prefix: `…/Profiles/work` is not inside
    /// `…/Profiles/wo`, though one string does begin with the other.
    private static func directoriesOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.pathComponents
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.pathComponents
        let shared = zip(left, right).prefix { $0 == $1 }.count
        return shared == left.count || shared == right.count
    }
}

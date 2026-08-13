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
        // This trashes the bundle at `appPath` and, on request, deletes the directory at
        // `profilePath` — so it must be established that the two belong together, and to this
        // profile. Otherwise a profile pointed at another bundle trashes *that* application
        // while purging its own credentials.
        let profile = try profileMatchingItsLauncher(profile)
        if let pid = runningPID(for: profile) {
            throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
        }
        // Refused *before* the launcher is trashed, unlike every other reason a purge does not
        // happen. Those leave the data reachable: a launcher on the same directory, or one
        // whose directory contains it, can still purge it later. This case cannot — purging
        // the inner launcher deletes only the inner directory, and with the outer launcher in
        // the Trash nothing in the app can ever offer to delete the rest. So the removal stops
        // here instead, with both remedies named, and nothing has happened yet to undo.
        if purgeProfile {
            let nested = launchersNested(under: profile)
            guard nested.isEmpty else {
                throw ClaudeManagerError.profileDataHoldsAnother(
                    name: profile.displayName, others: nested
                )
            }
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
        //
        // The scan has to be *readable* before its emptiness means anything: `scan` reports an
        // unlistable install directory as holding no launchers, and this call site would read
        // that as "nobody else claims this directory" and delete a sibling's login. `Doctor`
        // guards the same degradation, and `scan`'s doc comment warns about it by name.
        guard (try? fileManager.contentsOfDirectory(atPath: configuration.installDirectory.path))
            != nil
        else { return .keptOwnersUnknown }
        let survivors = bundle.scan(installDirectory: configuration.installDirectory)
        let sharing = survivors.filter {
            Self.directoriesOverlap($0.marker.profile, profile.profilePath)
        }
        // The default profile owns no launcher, so it appears in no scan and the sharing check
        // cannot see it — yet pointing a clone at its directory to reuse an existing login is
        // a supported thing to do (`AddResult.reusedProfileData` exists for it). Purging there
        // would take the user's primary Anthropic login and every chat in it, and even the
        // running check cannot object: Claude's own process carries no `--user-data-dir` for
        // `runningPID` to match.
        let isDefaultProfileData = PathUtils
            .sameDirectory(profile.profilePath, configuration.defaultProfileUserDataPath)
        // Existence first, so a refusal is only reported where there is something to refuse
        // over: with the directory already gone, "your login was kept" names credentials that
        // are not there and sends the user to remove a launcher for nothing.
        guard fileManager.fileExists(atPath: profile.profilePath) else {
            // The overlay is swept even here — it is created independently of the data dir —
            // but not when the path is shared, where it is the survivor's overlay too, nor
            // when it is the default profile's, where it is Claude's own config tier.
            if sharing.isEmpty, !isDefaultProfileData {
                sweepOverlay(for: profile, survivors: survivors)
            }
            return .alreadyGone
        }
        guard !isDefaultProfileData else { return .keptForDefaultProfile }
        guard sharing.isEmpty else {
            return .keptSharedWith(launchers: sharing.map(\.profile.displayName))
        }
        do {
            try fileManager.removeItem(at: profile.profileURL)
        } catch {
            // The overlay stays: this profile's data is still on disk, and the overlay is what
            // keeps Claude's own updater out of it.
            return .purgeFailed(reason: Sentences.reason(error))
        }
        sweepOverlay(for: profile, survivors: survivors)
        return .purged
    }

    /// Remove the `<profilePath>-3p` overlay sibling. Guards a name collision: if another
    /// launcher's user-data dir *is* that `-3p` path, it's that profile's data, not our
    /// overlay — leave it alone. `removeOverlay` deletes that directory whole, so missing the
    /// collision costs the sibling its login and chat history; the paths are therefore
    /// compared as directories, since the sibling records whichever spelling it was created
    /// with. Best-effort (`removeOverlay` no-ops when absent).
    private func sweepOverlay(for profile: Profile, survivors: [LauncherBundle.Discovered]) {
        let overlayPath = ManagedConfigWriter
            .localTierURL(forUserDataPath: profile.profilePath).path
        let overlayIsAnothersData = survivors.contains {
            PathUtils.sameDirectory($0.marker.profile, overlayPath)
        }
        if !overlayIsAnothersData {
            try? managedConfigWriter.removeOverlay(userDataPath: profile.profilePath)
        }
    }

    /// Display names of the launchers whose user-data directory sits **strictly inside**
    /// `profile`'s — the case a purge cannot be talked out of afterwards. This runs before the
    /// launcher is trashed, so it filters `profile` out of the scan itself rather than relying
    /// on the removal having already happened.
    private func launchersNested(under profile: Profile) -> [String] {
        let ourApp = profile.appURL.standardizedFileURL.path
        return bundle.scan(installDirectory: configuration.installDirectory)
            .filter { $0.appURL.standardizedFileURL.path != ourApp }
            .filter { Self.directoryStrictlyContains(profile.profilePath, $0.marker.profile) }
            .map(\.profile.displayName)
    }

    /// Whether deleting one of these directories would take the other with it — the same path,
    /// or one nested inside the other.
    ///
    /// Raw string equality is not enough on either count. The profile path is free text when a
    /// profile is created, so one launcher's data can sit *inside* another's: `removeItem` on
    /// the outer one is recursive and takes the inner profile's Anthropic token and chat
    /// history with it, silently, since a scan filtered on equality reports nobody sharing.
    ///
    /// Compared by path *component*, never by string prefix: `…/Profiles/work` is not inside
    /// `…/Profiles/wo`, though one string does begin with the other. And the components come
    /// from `PathUtils.canonicalPath`, not from the recorded spelling: `…/Profiles/shared` and
    /// `…/ProfilesLink/shared` are one directory, as are `…/work` and `…/Work` on a
    /// case-insensitive volume, and a comparison that misses that deletes the sibling's login
    /// while reporting a clean removal.
    private static func directoriesOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        let shared = zip(left, right).prefix { $0 == $1 }.count
        return shared == left.count || shared == right.count
    }

    /// Whether `inner` sits strictly below `outer` — the asymmetric half of the check above.
    private static func directoryStrictlyContains(_ outer: String, _ inner: String) -> Bool {
        let outerParts = components(outer)
        let innerParts = components(inner)
        guard innerParts.count > outerParts.count else { return false }
        return Array(innerParts.prefix(outerParts.count)) == outerParts
    }

    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: PathUtils.canonicalPath(path)).pathComponents
    }
}

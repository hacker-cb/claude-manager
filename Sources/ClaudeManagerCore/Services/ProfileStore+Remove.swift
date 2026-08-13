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
        // Two refusals happen *before* the launcher is trashed, unlike every other reason a
        // purge does not go through. Those others leave the data reachable — a launcher on the
        // same directory can still purge it later — while these two do not: afterwards no
        // profile lists the directory at all, so nothing in the app can offer to finish the job
        // and every message would name a remedy the user cannot follow. Stopping here leaves
        // nothing to undo.
        //
        // Only where something is actually going to be deleted. With the data already gone, or
        // with it belonging to the default profile, the purge deletes nothing whatever the scan
        // says — so demanding a readable launcher folder there would refuse a removal that was
        // never a risk, and leave the launcher installed with no way to retire it.
        if purgeProfile, purgeHasACandidate(profile) {
            // Same reasoning as below, one step earlier: with the launcher folder unlistable
            // there is no way to tell who else uses this data, and every answer that could be
            // given afterwards is a dead end — the launcher is in the Trash by then, so no
            // profile lists the directory any more and nothing in the app can offer to delete
            // it. Stop while the launcher is still installed, so making the folder readable and
            // trying again is the whole remedy.
            //
            // One scan answers both questions, rather than probing readability and then
            // rescanning: between two listings the folder can change state, and the second
            // one's emptiness would again read as "nobody claims this".
            let scan = bundle.scan(installDirectory: configuration.installDirectory)
            guard scan.isComplete else {
                throw ClaudeManagerError.launcherFolderUnreadable(
                    path: configuration.installDirectory.path
                )
            }
            let nested = launchersNested(under: profile, among: scan.launchers)
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
        // The scan has to be *complete* before its emptiness means anything: an unlistable
        // folder, or a bundle in it that cannot be read, reports the same "no launchers" an
        // empty folder does — and reading that as "nobody else claims this directory" deletes
        // a sibling's login. `remove` refuses up front for that reason; this is the residue,
        // the folder having changed state since. `Doctor` guards the same degradation.
        let scan = bundle.scan(installDirectory: configuration.installDirectory)
        let ownersKnown = scan.isComplete
        let survivors = scan.launchers
        let reach = PurgeReach(profile)
        let sharing = survivors.filter { reach.covers($0.marker.profile) }
        // The default profile owns no launcher, so it appears in no scan and the sharing check
        // cannot see it — yet pointing a clone at its directory to reuse an existing login is
        // a supported thing to do (`AddResult.reusedProfileData` exists for it). Purging there
        // would take the user's primary Anthropic login and every chat in it, and even the
        // running check cannot object: Claude's own process carries no `--user-data-dir` for
        // `runningPID` to match.
        let isDefaultProfileData = PathUtils
            .sameDirectory(profile.profilePath, configuration.defaultProfileUserDataPath)
        // Both of the answers below are known without a scan, so they come first: "there was
        // nothing to delete" and "this is Claude's own directory" stay true however little we
        // could see, and reporting the unknown instead would claim data was left behind that
        // either does not exist or was never a candidate.
        guard fileManager.fileExists(atPath: profile.profilePath) else {
            // The overlay is swept even here — it is created independently of the data dir —
            // but not when the path is shared, where it is the survivor's overlay too, nor
            // when it is the default profile's, where it is Claude's own config tier, nor when
            // the survivors could not be listed: the sweep's own collision guard reads them,
            // and an empty list would let it delete a launcher's data as if it were an overlay.
            if ownersKnown, sharing.isEmpty, !isDefaultProfileData {
                sweepOverlay(for: profile, survivors: survivors)
            }
            return .alreadyGone
        }
        guard !isDefaultProfileData else { return .keptForDefaultProfile }
        guard ownersKnown else { return .keptOwnersUnknown }
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
        let canonicalOverlay = PathUtils.canonicalPath(overlayPath)
        let overlayIsAnothersData = survivors.contains {
            $0.marker.profile == overlayPath
                || PathUtils.canonicalPath($0.marker.profile) == canonicalOverlay
        }
        if !overlayIsAnothersData {
            try? managedConfigWriter.removeOverlay(userDataPath: profile.profilePath)
        }
    }

    /// Display names of the launchers whose user-data directory sits **strictly inside**
    /// `profile`'s — the case a purge cannot be talked out of afterwards. This runs before the
    /// launcher is trashed, so it filters `profile` out of the scan itself rather than relying
    /// on the removal having already happened.
    private func launchersNested(
        under profile: Profile,
        among launchers: [LauncherBundle.Discovered]
    ) -> [String] {
        // A symlinked data path is unlinked, not walked, so nothing under its target is at
        // risk — `purgeWouldReach` says why in full.
        guard !Self.isSymbolicLink(profile.profileURL) else { return [] }
        let ourApp = profile.appURL.standardizedFileURL.path
        let ourData = PathUtils.canonicalPath(profile.profilePath)
        return launchers
            .filter { $0.appURL.standardizedFileURL.path != ourApp }
            .filter {
                Self.directoryStrictlyContains(ourData, PathUtils.canonicalPath($0.marker.profile))
            }
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
    /// Whether this removal has any data to delete at all: none where the directory is
    /// already gone, and none where it is the default profile's, which is refused outright.
    private func purgeHasACandidate(_ profile: Profile) -> Bool {
        fileManager.fileExists(atPath: profile.profilePath)
            && !PathUtils.sameDirectory(
                profile.profilePath, configuration.defaultProfileUserDataPath
            )
    }

    /// Whether purging one profile's data would reach the directory another one records.
    ///
    /// A value rather than a function because the answer canonicalises paths — which walks the
    /// file system — and one side of every comparison is the same throughout a removal. Built
    /// once per removal, it costs one canonicalisation plus one per launcher instead of two
    /// per launcher; on an install where some profile's data lives on a stale network mount,
    /// each avoided call is one avoided stall. `liveRewrite` hoists the same way.
    struct PurgeReach {
        private let profilePath: String
        private let canonical: String
        /// `removeItem` on a symbolic link unlinks the link and touches nothing under its
        /// target, so a profile whose data path is a link puts no other profile's data at risk
        /// — however deeply their recorded paths nest once the link is resolved. Treating it
        /// as containment would refuse the removal outright *and* point the user at a launcher
        /// whose data is genuinely destroyed if they follow the advice. Only a launcher
        /// recording that same link is affected.
        private let isLink: Bool

        init(_ profile: Profile) {
            profilePath = profile.profilePath
            canonical = PathUtils.canonicalPath(profile.profilePath)
            isLink = ProfileStore.isSymbolicLink(profile.profileURL)
        }

        func covers(_ other: String) -> Bool {
            // The literal test first: it settles the ordinary case without touching the disk.
            if other == profilePath { return true }
            guard !isLink else { return PathUtils.canonicalPath(other) == canonical }
            return ProfileStore.directoriesOverlap(canonical, PathUtils.canonicalPath(other))
        }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func directoriesOverlap(_ lhs: String, _ rhs: String) -> Bool {
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

    /// Components of an **already canonical** path — every caller canonicalises first, so
    /// doing it again here would pay for the file-system walk twice per comparison.
    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
    }
}

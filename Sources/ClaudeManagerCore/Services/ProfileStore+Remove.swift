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
        // go through. The others leave the data reachable — a launcher on the same directory
        // can still purge it later — while this one does not: afterwards no profile lists the
        // directory at all, so nothing in the app can offer to finish the job. Stopping here
        // leaves nothing to undo.
        //
        // Only where something is actually going to be deleted: with the data already gone, or
        // with it belonging to the default profile, nothing is at stake whatever the scan says.
        //
        // An *incomplete* scan is deliberately not refused here. It is computed over every
        // `.app` in the install directory — which is the real Claude.app's own folder, normally
        // `/Applications` — so one unreadable stranger there (installed by another account, an
        // MDM package, an evicted cloud placeholder) would block "delete profile data" for
        // every profile, forever, naming an app that has nothing to do with any of them. The
        // data is protected further down instead, where the answer is only ever "keep it".
        if purgeProfile, purgeHasACandidate(profile) {
            let scan = bundle.scan(installDirectory: configuration.installDirectory)
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
        // Asked as containment, not equality: the purge is a recursive `removeItem`, and the
        // "Profile data" field is free text, so a profile can be created on an *ancestor* of
        // Claude's own directory — `~/Library/Application Support`. Equality lets that through
        // and the deletion takes the user's real Claude login, their whole chat history, and
        // every other app's data in there, reported as a clean purge.
        let isDefaultProfileData = reach.reaches(configuration.defaultProfileUserDataPath)
        // Both of the answers below are known without a scan, so they come first: "there was
        // nothing to delete" and "this is Claude's own directory" stay true however little we
        // could see, and reporting the unknown instead would claim data was left behind that
        // either does not exist or was never a candidate.
        guard fileManager.fileExists(atPath: profile.profilePath) else {
            // The overlay is swept even here — it is created independently of the data dir —
            // but not when the path is shared, where it is the survivor's overlay too, nor
            // when it is the default profile's, where it is Claude's own config tier, nor when
            // the scan was incomplete: `removeOverlay` deletes that path recursively, and its
            // collision guard reads the very survivor list the scan could not complete. A `-3p`
            // tier left behind is recoverable; a sibling whose user-data directory *is* that
            // path is not.
            if ownersKnown, sharing.isEmpty, !isDefaultProfileData {
                sweepOverlay(for: profile, survivors: survivors)
            }
            return .alreadyGone
        }
        guard !isDefaultProfileData else { return .keptForDefaultProfile }
        // A sharer that *was* seen is named, even where the scan is otherwise incomplete: the
        // unknown is the weaker answer of the two, and reporting it instead would replace a
        // launcher's name with "delete the folder by hand if you are sure nothing else uses
        // it" — advice that destroys the very login this refusal exists to keep.
        guard sharing.isEmpty else {
            return .keptSharedWith(launchers: sharing.map(\.profile.displayName))
        }
        guard ownersKnown else { return .keptOwnersUnknown }
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
        // Asked exactly as the purge itself is asked, because `removeOverlay` deletes this
        // path the same recursive way: a launcher whose data sits *inside* the `-3p` path is
        // reached as surely as one whose data is that path, and an overlay path that is itself
        // a link would only be unlinked. Equality alone missed both.
        let reach = PurgeReach(path: overlayPath, url: URL(fileURLWithPath: overlayPath))
        let overlayIsAnothersData = survivors.contains { reach.covers($0.marker.profile) }
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
        // A link-valued data path is never this case. Unlinking destroys nothing, so the
        // refusal's own message — "deleting it would delete their login and chat history too,
        // remove that launcher first" — would be false, and following its advice is what
        // actually destroys that data. A sibling reached through the link is still seen, by
        // `PurgeReach`, and comes back as the decline it really is.
        guard !Self.isSymbolicLink(profile.profileURL) else { return [] }
        let ourApp = profile.appURL.standardizedFileURL.path
        let ourLiteral = PurgeReach.literalPath(profile.profilePath)
        let ourCanonical = PathUtils.canonicalPath(profile.profilePath)
        let ignoringCase = Self.volumeIgnoresCase(at: profile.profileURL)
        return launchers
            .filter { $0.appURL.standardizedFileURL.path != ourApp }
            .filter {
                // Both questions, for the reasons `PurgeReach` sets out: a sibling can sit
                // under this directory by canonical path (another spelling of it) or only by
                // the path it recorded (through a symlink inside it).
                Self.directoryStrictlyContains(
                    ourLiteral,
                    PurgeReach.literalPath($0.marker.profile),
                    ignoringCase: ignoringCase
                ) || Self.directoryStrictlyContains(
                    ourCanonical, PathUtils.canonicalPath($0.marker.profile)
                )
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
            && !PurgeReach(profile).reaches(configuration.defaultProfileUserDataPath)
    }

    /// Whether purging one profile's data would reach the directory another one records.
    ///
    /// A value rather than a function because the answers canonicalise paths — which walks the
    /// file system — and one side of every comparison is the same throughout a removal. Built
    /// once per removal, it costs a fixed handful of canonicalisations plus one per launcher;
    /// on an install where some profile's data lives on a stale mount, each avoided call is an
    /// avoided stall. `liveRewrite` hoists the same way.
    ///
    /// "Reach" is not one question, and answering it with one comparison is what every bug
    /// here has been:
    ///
    /// - **Recursive delete of a directory** takes everything physically under it, so a
    ///   sibling recording another spelling of that directory (`…/ProfilesLink/x`) is reached —
    ///   a *canonical* comparison.
    /// - It also takes any **symlink sitting inside** it, stranding a sibling that recorded its
    ///   path through that link even though the bytes survive — a *literal* comparison. Neither
    ///   test subsumes the other, so both are asked.
    /// - **Unlinking a link** (when the purged path is itself one) deletes nothing under the
    ///   target, so containment there is not containment at all. What it reaches is whatever
    ///   was spelled through the link — literal again — plus any spelling of *that same link*,
    ///   which is the link's parent resolved with its own name left alone.
    struct PurgeReach {
        private let literal: String
        private let canonical: String
        private let linkIdentity: String?
        private let ignoringCase: Bool

        init(_ profile: Profile) {
            self.init(path: profile.profilePath, url: profile.profileURL)
        }

        init(path: String, url: URL) {
            literal = Self.literalPath(path)
            canonical = PathUtils.canonicalPath(path)
            linkIdentity = ProfileStore.isSymbolicLink(url) ? Self.linkIdentityPath(path) : nil
            ignoringCase = ProfileStore.volumeIgnoresCase(at: url)
        }

        /// Whether purging this profile would reach `other` — **directionally**. `covers` asks
        /// whether the two overlap either way round, which is the right question for a sibling
        /// (deleting a directory inside theirs takes part of their data). It is the wrong one
        /// for a directory this removal must never touch: a profile at `<default>/moved/work`,
        /// where `moved` is a link to another volume, overlaps the default profile's path
        /// lexically while `removeItem` resolves the link and deletes something else entirely.
        /// Refusing there strands the profile's own data for no reason.
        func reaches(_ other: String) -> Bool {
            let theirLiteral = Self.literalPath(other)
            guard linkIdentity == nil else {
                // Unlinking reaches the link itself and whatever was spelled through it.
                return ProfileStore.directoryContains(literal, theirLiteral, ignoringCase: ignoringCase)
            }
            return ProfileStore.directoryContains(literal, theirLiteral, ignoringCase: ignoringCase)
                || ProfileStore.directoryContains(
                    canonical, PathUtils.canonicalPath(other), ignoringCase: ignoringCase
                )
        }

        func covers(_ other: String) -> Bool {
            if let linkIdentity {
                // Anything spelled through this link is stranded by the unlink. "Through it"
                // has to be asked of every prefix of the sibling's path, not just of the path
                // itself: `…/ProfilesLink/alias/inner` runs through `…/Profiles/alias` while
                // resolving to something else entirely, and comparing only the whole path
                // resolves the link away before the comparison can see it.
                var probe = URL(fileURLWithPath: other).standardizedFileURL
                while probe.pathComponents.count > 1 {
                    if ProfileStore.samePath(
                        Self.linkIdentityPath(probe.path), linkIdentity, ignoringCase: ignoringCase
                    ) { return true }
                    probe = probe.deletingLastPathComponent()
                }
                // And the link *is* an entry in its own parent, so a launcher owning that
                // parent owns it: unlinking changes that profile's directory. Asked with the
                // parent resolved and the link's own name left alone, so the target — a
                // different place, which this removal does not touch — is not mistaken for it.
                return ProfileStore.directoriesOverlap(
                    literal, Self.literalPath(other), ignoringCase: ignoringCase
                ) || ProfileStore.directoriesOverlap(
                    linkIdentity, PathUtils.canonicalPath(other), ignoringCase: ignoringCase
                )
            }
            return ProfileStore.directoriesOverlap(
                literal, Self.literalPath(other), ignoringCase: ignoringCase
            ) || ProfileStore.directoriesOverlap(canonical, PathUtils.canonicalPath(other))
        }

        /// The path as recorded, `.`/`..` folded and nothing resolved.
        static func literalPath(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        /// What identifies a **link itself**: its parent resolved, its own name untouched. Two
        /// spellings of one link agree here, while the link's target — a different thing, and
        /// one this removal does not delete — does not pass for it.
        static func linkIdentityPath(_ path: String) -> String {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return PathUtils.canonicalPath(url.deletingLastPathComponent().path)
                + "/" + url.lastPathComponent
        }
    }

    /// Whether the volume holding `url` treats names case-insensitively — the default on
    /// macOS. Unknown answers assume it does, since folding too eagerly costs a refusal while
    /// not folding costs a deletion.
    static func volumeIgnoresCase(at url: URL) -> Bool {
        let sensitive = (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames
        return sensitive != true
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// The same overlap question asked of the paths **as recorded**, with no symlink
    /// resolution — what `PurgeReach` needs for a link, whose unlink reaches whatever was
    /// spelled through it and nothing else.
    static func directoriesOverlapLiterally(_ lhs: String, _ rhs: String) -> Bool {
        directoriesOverlap(
            URL(fileURLWithPath: lhs).standardizedFileURL.path,
            URL(fileURLWithPath: rhs).standardizedFileURL.path
        )
    }

    /// Whether `inner` is `outer` or sits below it — the asymmetric question, for "would
    /// deleting `outer` reach `inner`".
    static func directoryContains(
        _ outer: String,
        _ inner: String,
        ignoringCase: Bool = false
    ) -> Bool {
        let outerParts = components(outer)
        let innerParts = components(inner)
        guard innerParts.count >= outerParts.count else { return false }
        return zip(outerParts, innerParts).allSatisfy { same($0, $1, ignoringCase: ignoringCase) }
    }

    static func directoriesOverlap(
        _ lhs: String,
        _ rhs: String,
        ignoringCase: Bool = false
    ) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        let shared = zip(left, right).prefix { same($0, $1, ignoringCase: ignoringCase) }.count
        return shared == left.count || shared == right.count
    }

    /// Component equality, folded the way the volume folds it. The canonical comparison gets
    /// this from the file system for free — an existing path resolves to the name actually
    /// stored — but the *literal* one cannot, and on a case-insensitive volume that leaves
    /// `…/Outer/alias/inner` and `…/outer/Alias/inner` looking unrelated while both name one
    /// directory reached through one link.
    private static func same(_ lhs: String, _ rhs: String, ignoringCase: Bool) -> Bool {
        ignoringCase ? lhs.caseInsensitiveCompare(rhs) == .orderedSame : lhs == rhs
    }

    /// Whole-path equality, folded the way the volume folds names — the same question `same`
    /// answers per component.
    static func samePath(_ lhs: String, _ rhs: String, ignoringCase: Bool) -> Bool {
        same(lhs, rhs, ignoringCase: ignoringCase)
    }

    /// Whether `inner` sits strictly below `outer` — the asymmetric half of the check above.
    private static func directoryStrictlyContains(
        _ outer: String,
        _ inner: String,
        ignoringCase: Bool = false
    ) -> Bool {
        let outerParts = components(outer)
        let innerParts = components(inner)
        guard innerParts.count > outerParts.count else { return false }
        return zip(outerParts, innerParts).allSatisfy { same($0, $1, ignoringCase: ignoringCase) }
    }

    /// Components of an **already canonical** path — every caller canonicalises first, so
    /// doing it again here would pay for the file-system walk twice per comparison.
    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
    }
}

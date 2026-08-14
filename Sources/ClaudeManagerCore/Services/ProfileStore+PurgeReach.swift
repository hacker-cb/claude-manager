import Foundation

/// What a purge would reach, and how that question has to be asked. Split out of
/// `ProfileStore+Remove` to keep that file within its length budget.
extension ProfileStore {
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
            // Both spellings, link or not — and unlike `covers`, the *target* of a link counts
            // here. This question is asked by the guard over Claude's own directory, where the
            // answer decides what the user is told: a profile that is a link to that directory
            // has its data untouched by the unlink, so reporting "profile data deleted" would
            // tell someone revoking access that the session is gone while it is still there.
            ProfileStore.directoryContains(
                literal, Self.literalPath(other), ignoringCase: ignoringCase
            ) || ProfileStore.directoryContains(
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
            // Asked of the path as recorded *and* of it with the parent resolved — see
            // `launchersNested` for why neither form alone sees every shortcut.
            return ProfileStore.directoriesOverlap(
                literal, Self.literalPath(other), ignoringCase: ignoringCase
            ) || ProfileStore.directoriesOverlap(
                literal, Self.linkIdentityPath(other), ignoringCase: ignoringCase
            ) || ProfileStore.directoriesOverlap(
                canonical, PathUtils.canonicalPath(other), ignoringCase: ignoringCase
            )
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
}

import Foundation

/// Where a rebuilt launcher ends up, and putting it under the name it was asked for. Split out
/// of `LauncherBundle` to keep that file within its length budget.
extension LauncherBundle {
    /// What one build left on disk.
    public struct BuildResult: Sendable {
        /// Whether the badge icon changed vs. what was installed at this path, so a caller can
        /// skip the screen-flashing Dock refresh when it didn't.
        public let iconChanged: Bool
        /// **Where the bundle actually ended up**, which is not always the path it was asked
        /// for: `replaceItemAt` keeps the name of the file it replaces, so a build under a new
        /// spelling depends on a rename that the volume can decline to make possible. Reported
        /// rather than left to each caller to re-derive — `Profile.id` *is* this path, and
        /// three call sites each inferring it from their own later lookup is three chances to
        /// hand back an id no scan will ever produce.
        public let appPath: String
        /// False when the volume would not say what the launcher is stored under, so `appPath`
        /// is the requested spelling for want of a better answer rather than a read one. A
        /// caller that knows the previous spelling — `update` does — should prefer it.
        public let spellingCertain: Bool
    }

    /// Bring the bundle already installed here under the name this build was asked for, so the
    /// swap that follows lands where it says it does.
    ///
    /// `replaceItemAt` writes into the file **already at the path and keeps that file's name**
    /// (measured, not inferred from the docs). On a case-insensitive volume `WORK.app` *is* the
    /// installed `Work.app`, so a build asked for a new spelling would write every byte it
    /// promised and return with the old name still on disk — and the rest of the app takes
    /// `profile.appPath` at its word. `Profile.id` is that path; `update` re-derives it from the
    /// display name and compares; `liveRewrite` matches the scanned bundle against it. So the
    /// quiet version of this is a launcher whose marker says one name and whose file says
    /// another: one bundle under two identities, which is the shape `scan` was fixed to stop
    /// producing. It also reaches `add(force:)`, where re-creating a profile under a new
    /// spelling silently kept the old one.
    ///
    /// **Before the swap, deliberately.** This step can fail — the bundle renamed from Finder
    /// mid-build, the install directory losing write permission — and every other failure in
    /// `build` happens while the previous launcher is still whole. Run afterwards it would throw
    /// with the rebuilt bundle already installed under the *old* name: the edit reported as
    /// failed, the marker already carrying the new display name, and exactly the split identity
    /// this function exists to prevent. Run first, a failure leaves the launcher untouched and
    /// the caller free to report an edit that did not happen. It renames the *installed* bundle,
    /// which this build has not written to and whose seal it does not touch; the staging copy is
    /// signed and swapped in afterwards, so signing remains the last write into what ships.
    ///
    /// What is moved is decided by **identity**, never by a case rule of our own. The volume is
    /// the only authority on which two spellings it folds, and its rules are not `lowercased()`:
    /// APFS opens `Σ.app`, `σ.app` and `ς.app` as one file, while `"Σ".lowercased()` is `σ` and
    /// `"ς".lowercased()` is `ς` — so a guard written that way declines to rename exactly where
    /// the collision is real, which is the case this function exists for. Asking whether the
    /// requested path opens the file about to be moved covers every folding the volume does, and
    /// still refuses to move a *different* file, which is all the guard was ever for. Declining
    /// is safe here in a way it would not be after the swap: the build carries on and
    /// `replaceItemAt` behaves as it always did, rather than leaving a caller that has already
    /// acted on the promise of a rename.
    ///
    /// The outcome, because "nothing was renamed" covers two states the caller has to tell
    /// apart: the bundle was already stored under the requested name, and the stored name could
    /// not be established at all. Only the first lets anyone say where the bundle ended up.
    func alignInstalledSpelling(with appURL: URL) throws -> SpellingAlignment {
        guard let stored = PathUtils.spellingOnDisk(appURL.path) else { return .unknown }
        guard stored != appURL.path else { return .alreadyMatching }
        guard PathUtils.sameFile(stored, appURL.path) else { return .unknown }
        let onDisk = URL(fileURLWithPath: stored)
        try fileManager.moveItem(at: onDisk, to: appURL)
        return .renamed(from: onDisk)
    }

    /// What `alignInstalledSpelling` did, and whether the answer is known.
    enum SpellingAlignment {
        /// The bundle is stored under the requested name; nothing to do.
        case alreadyMatching
        /// Renamed, from the URL it was reachable at before. Carried so the caller can put the
        /// name back if the swap that follows fails — the one part of a failed build that does
        /// not undo itself.
        case renamed(from: URL)
        /// The volume would not say what the bundle is stored under, or the path stopped opening
        /// the file whose name was read. The build carries on — see above — but nothing may be
        /// claimed afterwards about which name the launcher answers to.
        case unknown
    }
}

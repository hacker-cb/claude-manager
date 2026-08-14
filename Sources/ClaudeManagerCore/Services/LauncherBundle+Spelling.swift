import Foundation

/// Putting a rebuilt launcher under the name it was asked for. Split out of `LauncherBundle` to
/// keep that file within its length budget.
extension LauncherBundle {
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
    /// Returns the URL the bundle was reachable at **before** this call, or `nil` when nothing
    /// was renamed — the caller needs it to put the name back if the swap then fails, since this
    /// is the one part of a failed build that does not undo itself.
    func alignInstalledSpelling(with appURL: URL) throws -> URL? {
        let requested = appURL.lastPathComponent
        guard let installed = (try? appURL.resourceValues(forKeys: [.nameKey]))?.name,
              installed != requested
        else { return nil }
        let onDisk = appURL.deletingLastPathComponent().appendingPathComponent(installed)
        guard PathUtils.sameFile(onDisk.path, appURL.path) else { return nil }
        try fileManager.moveItem(at: onDisk, to: appURL)
        return onDisk
    }
}

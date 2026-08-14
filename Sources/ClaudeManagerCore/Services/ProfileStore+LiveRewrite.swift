import Foundation

/// Deciding whether a rewrite left a running window showing something stale — the state
/// behind the app's "Restart to apply" nudge. Split out of `ProfileStore` to keep that file
/// within its length budget, and shared by `update` and `rebuild` so the two cannot answer
/// the question differently.
extension ProfileStore {
    /// The instance to nudge for a restart after `profile`'s bundle was rewritten — or `nil`
    /// when there is nothing for a restart to reveal.
    ///
    /// `presentationChanged` is what keeps the nudge honest. A running window can only show
    /// two things a rewrite touches: its **name** and its **badge**. A rebuild that
    /// regenerates a byte-identical bundle changes neither, and that is the common case —
    /// "Apply to all launchers" over already-current launchers hits it for every profile at
    /// once. Nudging there would ask the user to close live Claude sessions to reveal a
    /// change that does not exist, which is exactly what `dockRefreshPending` avoids by
    /// gating on the same evidence.
    ///
    /// The pid is sampled **after** the swap, not before. Rendering the badge shells out to
    /// `iconutil`, so a write is not instantaneous, and an instance can start during it —
    /// launched from the *old* bundle, since the swap has not happened yet. A probe taken up
    /// front misses that instance entirely (it reads "stopped"), or names a pid that has
    /// since been replaced, and either way the profile that most needs the nudge never gets
    /// it. Sampling here can instead catch an instance that started *after* the swap and
    /// already has the new bundle — an unnecessary nudge, which costs a restart the user can
    /// ignore. Between a nudge too many and a stale window nobody is told about, the extra
    /// nudge is the one to take.
    ///
    /// Nothing is claimed when the pid's owner is ambiguous. `runningPID` matches on the
    /// user-data dir, which is **not** unique — two launchers may point at one profile
    /// directory, a configuration `remove` already handles explicitly. Rewriting the idle
    /// one would then record the *other* one's pid, and the Restart offered against it stops
    /// a live session and launches a different launcher in its place. That is too disruptive
    /// to offer on a guess, so an ambiguous owner produces no nudge at all.
    ///
    /// Non-private so `ProfileStore+Rebuild` (another file) samples it the same way.
    func liveRewrite(for profile: Profile, presentationChanged: Bool) -> LiveRewrite? {
        guard presentationChanged, let pid = runningPID(for: profile) else { return nil }
        // The two comparisons below answer different questions, and each is written to fail
        // *towards withholding the nudge* — because what rides on it is a Restart that stops
        // someone's live session, while the cost of not offering one is a window showing last
        // session's badge until it is next reopened.
        //
        // Rivals: compared as directories. A literal comparison looks defensible — `mainPID`
        // anchors its `pgrep` pattern on the recorded spelling at both ends, so a sibling
        // holding another spelling launches an instance that pattern cannot match — but that
        // reasoning assumes the sibling's *script* execs what its *marker* records. `build`
        // writes the two together, and nothing re-checks them afterwards: a hand-edited marker
        // (which `profileMatchingItsLauncher` deliberately tolerates) leaves a launcher whose
        // instance answers our probe while its marker no longer matches our string. That
        // launcher is exactly the rival this guard exists to see.
        // The literal test runs first, and settles the common case without touching the disk:
        // canonicalising reaches the file system once per launcher, and this runs on Save and
        // on every launcher of "Apply to all". A sibling whose data directory sits on a stale
        // network mount would otherwise stall an edit that has nothing to do with it. What
        // survives to the canonical test is only what a plain comparison already rejected.
        let ourProfileDir = PathUtils.canonicalPath(profile.profilePath)
        let scan = bundle.scan(installDirectory: configuration.installDirectory)
        // An install directory that could not be listed answers "who else claims this
        // directory" the same way an empty one does — and this guard exists precisely to refuse
        // acting on that. A missing sibling here means the Restart is offered against a pid that
        // may be its, stopping someone's live session.
        guard scan.isComplete else { return nil }
        let sharingThisProfileDir = scan
            .launchers
            .filter {
                $0.marker.profile == profile.profilePath
                    || PathUtils.canonicalPath($0.marker.profile) == ourProfileDir
            }
        // Identity: compared as **strings**, and deliberately not canonicalised. `scan` reports
        // launchers under the install directory's own spelling and `profile.appPath` is derived
        // from that same directory, so equality here holds *by construction* — canonicalising
        // would paper over the very drift `scan`'s doc comment describes, leaving the lost-nudge
        // half of that bug undetectable at the site that produces it.
        //
        // `scan` also degrades an unreadable install directory to an empty list, so "no launcher
        // claims this profile dir" is "the scan told us nothing", not evidence of uniqueness —
        // and a `<=` here would read that failure as a clear answer and nudge anyway.
        guard sharingThisProfileDir.count == 1,
              sharingThisProfileDir[0].appURL.path == profile.appURL.path
        else { return nil }
        return LiveRewrite(profile: profile, pid: pid)
    }
}

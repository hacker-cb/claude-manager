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
        let sharingThisProfileDir = bundle.scan(installDirectory: configuration.installDirectory)
            .filter { $0.marker.profile == profile.profilePath }
        guard sharingThisProfileDir.count <= 1 else { return nil }
        return LiveRewrite(profile: profile, pid: pid)
    }
}

import ClaudeManagerCore
import Foundation

/// The "Restart to apply" nudge: which running instances predate the last rewrite of their
/// launcher, and when that stops being true. Split out of `AppModel` to keep that file
/// within its length budget.
///
/// A launcher can be edited or rebuilt while its profile is up — the live process does not
/// execute out of the bundle, so the write is safe (`LiveRewrite`). What the write cannot
/// reach is the running window, which keeps the name and Dock tile it launched with. That
/// gap is what this nudge names, per profile, instead of the old blanket refusal to edit a
/// running profile at all.
@MainActor
extension AppModel {
    /// Record launchers rewritten under a live instance, so each shows the nudge until that
    /// instance is restarted.
    func noteLiveRewrites(_ rewrites: [LiveRewrite]) {
        for rewrite in rewrites {
            pendingRestart[rewrite.profile.profilePath] = rewrite.pid
        }
    }

    /// Whether `managed`'s *running* instance predates the last rewrite of its launcher.
    ///
    /// Decided against the live pid rather than a stored flag, which is what makes the nudge
    /// retire itself: a restart hands out a new pid and a stop leaves none, so the recorded
    /// pid stops matching and the banner goes without anyone clearing it.
    func needsRestartToApply(_ managed: ManagedProfile) -> Bool {
        guard let pid = managed.pid else { return false }
        return pendingRestart[managed.profile.profilePath] == pid
    }

    /// Drop nudges with nothing left to say — the instance was restarted (new pid), stopped
    /// (no pid), or the profile is gone. `needsRestartToApply` already reads false for all
    /// three, so this is about not accumulating an entry per profile ever edited live, and
    /// about not letting a profile removed and re-added at the same user-data dir inherit a
    /// stale one. Called from `refresh`, where the fresh pids arrive.
    func prunePendingRestarts() {
        guard !pendingRestart.isEmpty else { return }
        var live: [String: Int32] = [:]
        for managed in profiles where managed.pid != nil {
            live[managed.profile.profilePath] = managed.pid
        }
        pendingRestart = pendingRestart.filter { path, pid in live[path] == pid }
    }
}

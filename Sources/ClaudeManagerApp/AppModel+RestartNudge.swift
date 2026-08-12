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
    /// instance is restarted. Keyed by launcher, not by user-data dir — see
    /// `AppModel.pendingRestart`.
    func noteLiveRewrites(_ rewrites: [LiveRewrite]) {
        for rewrite in rewrites {
            pendingRestart[rewrite.profile.id] = rewrite.pid
        }
    }

    /// Whether `managed`'s *running* instance predates the last rewrite of its launcher.
    ///
    /// Decided against the live pid rather than a stored flag, which is what makes the nudge
    /// retire itself: a restart hands out a new pid and a stop leaves none, so the recorded
    /// pid stops matching and the banner goes without anyone clearing it.
    func needsRestartToApply(_ managed: ManagedProfile) -> Bool {
        guard let pid = managed.pid else { return false }
        return pendingRestart[managed.profile.id] == pid
    }

    /// Drop one profile's nudge without restarting it — the user has seen it and wants the
    /// banner (and its sidebar mark) gone mid-session. Not a dead end: Restart stays on the
    /// detail pane and in the sidebar context menu, so the remedy outlives the reminder.
    func dismissRestartNudge(_ profile: Profile) {
        pendingRestart[profile.id] = nil
    }

    /// Drop nudges with nothing left to say — the instance was restarted (new pid), stopped
    /// (no pid), or the launcher is gone. `needsRestartToApply` already reads false for all
    /// three, so this is about not accumulating an entry per launcher ever rewritten live,
    /// and about not letting a launcher re-created at the same path inherit a stale one.
    /// Called from `refresh`, where the fresh pids arrive.
    func prunePendingRestarts() {
        guard !pendingRestart.isEmpty else { return }
        var live: [String: Int32] = [:]
        for managed in profiles where managed.pid != nil {
            live[managed.profile.id] = managed.pid
        }
        pendingRestart = pendingRestart.filter { id, pid in live[id] == pid }
    }
}

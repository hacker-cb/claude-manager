import ClaudeManagerCore
import Foundation

/// The opt-in Dock icon refresh. Split out of `AppModel` to keep that file within its
/// length budget.
///
/// Restarting the Dock is the only way this app can repaint an already-drawn pinned tile
/// after a launcher's badge changed, and it flashes the whole screen — so it is never done
/// silently, only from the post-rebuild banner or the standing button in Settings.
@MainActor
extension AppModel {
    /// Restart the Dock so pinned tiles repaint with the new icon — flashing the screen
    /// once, by explicit user request — and clear the banner. Reached from the post-rebuild
    /// banner and from the standing **Refresh Dock icons** button in Settings; the second is
    /// what keeps a dismissed banner from being a dead end, since nothing else can set
    /// `dockRefreshPending` again.
    func refreshDock() async {
        // `IconCache.restartDock` signals `iconservicesagent` and the Dock; neither has any
        // dependency on Claude.app, so run it directly rather than through `perform` — which
        // requires a located `realClaude` and would otherwise surface an unrelated "Claude
        // not found" error while never restarting anything. Off-main because it forks
        // subprocesses and waits briefly for the agent to exit. The banner clears
        // unconditionally afterwards: the attempt is best-effort (see `restartDock`), and
        // Settings carries the retry.
        await Task.detached { IconCache(runner: SystemCommandRunner()).restartDock() }.value
        dockRefreshPending = false
    }

    /// Dismiss the Dock-refresh banner without restarting the Dock, leaving pinned tiles on
    /// their old icon. Not a dead end: **Refresh Dock icons** in Settings runs the same
    /// action whenever the user wants it.
    func dismissDockRefresh() {
        dockRefreshPending = false
    }
}

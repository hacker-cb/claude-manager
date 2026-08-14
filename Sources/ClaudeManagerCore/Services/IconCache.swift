import Foundation

/// Nudges LaunchServices / IconServices / the Dock into picking up a launcher's icon.
///
/// The icon cache is sticky, and re-registering is not enough on its own to break it. A
/// launcher rebuild leaves every part of the bundle's *identity* untouched — same path,
/// same `CFBundleIdentifier`, same `CFBundleVersion` (we ship a fixed `1`) — so when it
/// also presents the same icon resource name, an `lsregister -f` + `touch` is answered
/// from the entry already rendered. The resource name is the one part of that identity
/// this app controls, which is why `LauncherBundle.iconFileName` derives it from the
/// icon's own bytes.
///
/// So the two steps here divide differently than their names suggest: `register` is the
/// no-flash step every write does, and it is what makes LaunchServices and Finder read
/// the bundle again; the screen-flashing `restartDock` is opt-in and is what repaints an
/// already-drawn, pinned tile.
public struct IconCache {
    let runner: CommandRunner
    /// Bounded wait for the signalled icon agent to actually exit — see `restartDock`.
    /// Injected for the same reason `AsyncPoll` injects its sleep: tests drive the loop
    /// instantly instead of sleeping through it.
    let agentExitAttempts: Int
    let agentExitInterval: TimeInterval

    public init(
        runner: CommandRunner,
        agentExitAttempts: Int = 20,
        agentExitInterval: TimeInterval = 0.1
    ) {
        self.runner = runner
        self.agentExitAttempts = agentExitAttempts
        self.agentExitInterval = agentExitInterval
    }

    /// Re-register the bundle so LaunchServices and Finder pick up the rewritten icon on
    /// their next fetch. Never restarts the Dock, so it never flashes the screen: this is
    /// the `touch` + re-register that Sparkle-style updaters lean on (a modification-date
    /// bump is LaunchServices' change signal). An already-drawn Dock tile of a pinned
    /// launcher is a separate, opaque cache this does not reach; `restartDock()` is what
    /// repaints it.
    public func register(appURL: URL) {
        _ = try? runner.run(CoreConstants.lsregisterPath, ["-f", appURL.path])
        _ = try? runner.run(CoreConstants.touchPath, [appURL.path])
    }

    /// Restart the Dock once — the only way this app can force an already-displayed,
    /// pinned tile to repaint after its icon changed, but it flashes the whole screen (the
    /// Dock process repaints the desktop wallpaper as it relaunches). Never called silently
    /// by a rebuild: the app offers it as an explicit "Refresh Dock now" action.
    ///
    /// `iconservicesagent` is signalled first, and the order is what makes the pairing
    /// worth anything: the Dock does not render the image it draws, it asks that agent, so
    /// restarting the Dock alone hands it straight back to a live process holding the old
    /// render. Both are launchd-managed and return on demand.
    ///
    /// What this is **not** is a guarantee. The agent also reads a persistent on-disk store
    /// that only root can remove, so a relaunched agent can answer a *pre-v4* launcher's
    /// request from the same stale entry: for those bundles the honest remedy is the
    /// rebuild that moves them onto a content-addressed name, and this is a best-effort
    /// nudge rather than the fix. Post-v4 the new name is a key nothing has rendered yet,
    /// which is what actually makes the repaint stick.
    public func restartDock() {
        _ = try? runner.run(CoreConstants.killallPath, ["iconservicesagent"])
        waitForIconAgentToExit()
        _ = try? runner.run(CoreConstants.killallPath, ["Dock"])
    }

    /// Wait, briefly and with a bound, for the signalled agent to actually be gone.
    ///
    /// `killall` only *sends* SIGTERM and returns, so the two calls above order signal
    /// delivery, not termination: without this the Dock can relaunch and query an agent
    /// that is still alive, and be handed the very render the refresh meant to drop. macOS
    /// `killall` has no `-w` to do the waiting — that flag is the Linux one — so the wait
    /// is an explicit poll. Bounded on purpose: an agent that will not die delays the
    /// refresh by the budget and then lets it proceed, since restarting the Dock anyway
    /// beats hanging the action that was supposed to fix the user's icon.
    private func waitForIconAgentToExit() {
        for _ in 0 ..< agentExitAttempts {
            // pgrep exits non-zero when nothing matched — that is the agent being gone.
            // A probe we cannot run tells us nothing, so stop waiting rather than stall.
            guard let probe = try? runner.run(CoreConstants.pgrepPath, ["-x", "iconservicesagent"]),
                  probe.exitCode == 0
            else { return }
            Thread.sleep(forTimeInterval: agentExitInterval)
        }
    }
}

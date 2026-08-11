import Foundation

/// Nudges LaunchServices / IconServices / the Dock into picking up a launcher's icon.
///
/// The icon cache is sticky, and re-registering is not enough on its own to break it:
/// IconServices keys a rendered icon on things a rebuild leaves untouched (the bundle
/// path, its `CFBundleIdentifier`, its `CFBundleVersion`), so an `lsregister -f` + `touch`
/// over a rewritten resource can still be answered from the old entry. What actually
/// invalidates it is the icon resource being a file the cache has never seen —
/// `LauncherBundle.iconFileName` names it after its own bytes for exactly that reason.
///
/// So the two steps here divide differently than their names suggest: `register` is the
/// no-flash step every write does, and it is what makes LaunchServices and Finder read
/// the bundle again; the screen-flashing `restartDock` is opt-in and is what repaints an
/// already-drawn, pinned tile.
public struct IconCache {
    let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
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

    /// Drop the rendered icon caches and restart the Dock once — the only reliable way to
    /// force an already-displayed, pinned tile to repaint after its icon changed, but it
    /// flashes the whole screen (the Dock process repaints the desktop wallpaper as it
    /// relaunches). Never called silently by a rebuild: the app offers it as an explicit
    /// "Refresh Dock now" action, and only when a rebuild actually changed an icon.
    ///
    /// `iconservicesagent` goes first and the order is the point: the Dock does not own
    /// the image it draws, it asks that agent, so restarting the Dock alone brings it back
    /// to a cache still holding the old badge. Killing the agent first means the relaunched
    /// Dock asks a process that has to render afresh. Both are launchd-managed and come
    /// back on demand; the transient cost is other apps' icons re-rendering once, which is
    /// invisible next to the screen flash the user already opted into.
    public func restartDock() {
        _ = try? runner.run(CoreConstants.killallPath, ["iconservicesagent"])
        _ = try? runner.run(CoreConstants.killallPath, ["Dock"])
    }
}

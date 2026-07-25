import Foundation

/// Nudges LaunchServices / IconServices / the Dock into picking up a launcher's
/// icon. The icon cache is sticky: after (re)writing a bundle's `.icns` a pinned Dock
/// tile keeps showing the old icon until either the launcher is next opened (it
/// self-heals on launch) or the Dock is restarted. Re-registration (`register`) is the
/// no-flash step every write does; the screen-flashing `restartDock` is opt-in.
public struct IconCache {
    let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Re-register the bundle so LaunchServices and Finder pick up the rewritten icon on
    /// their next fetch. Never restarts the Dock, so it never flashes the screen: this is
    /// the `touch` + re-register that Sparkle-style updaters lean on (a modification-date
    /// bump is LaunchServices' change signal). An already-drawn Dock tile of a pinned
    /// launcher is a separate, opaque cache; it self-heals the next time the launcher is
    /// opened, or is refreshed on demand via `restartDock()`.
    public func register(appURL: URL) {
        _ = try? runner.run(CoreConstants.lsregisterPath, ["-f", appURL.path])
        _ = try? runner.run(CoreConstants.touchPath, [appURL.path])
    }

    /// Restart the Dock once — the only reliable way to force an already-displayed,
    /// pinned tile to repaint after its icon changed, but it flashes the whole screen
    /// (the Dock process repaints the desktop wallpaper as it relaunches). Never called
    /// silently by a rebuild: the app offers it as an explicit "Refresh Dock now" action,
    /// and only when a rebuild actually changed an icon.
    public func restartDock() {
        _ = try? runner.run(CoreConstants.killallPath, ["Dock"])
    }
}

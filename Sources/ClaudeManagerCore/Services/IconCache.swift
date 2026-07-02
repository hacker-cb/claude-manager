import Foundation

/// Nudges LaunchServices / IconServices / the Dock into picking up a launcher's
/// icon. The icon cache is sticky: after (re)writing a bundle's `.icns` the Dock
/// keeps showing the old tile until the bundle is re-registered and, for a path
/// that had a cached icon before, the Dock is restarted.
public struct IconCache {
    let runner: CommandRunner
    let fileManager: FileManager

    public init(runner: CommandRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    /// Re-register the bundle and (optionally) restart the Dock. Restarting the
    /// Dock flashes the whole screen, so a brand-new bundle — which has nothing
    /// cached for its path — should pass `restartDock: false`.
    public func refresh(appURL: URL, restartDock: Bool) {
        _ = try? runner.run(CoreConstants.lsregisterPath, ["-f", appURL.path])
        _ = try? runner.run(CoreConstants.touchPath, [appURL.path])
        if restartDock {
            self.restartDock()
        }
    }

    /// Restart the Dock once (clears its sticky icon cache; flashes the screen).
    public func restartDock() {
        _ = try? runner.run(CoreConstants.killallPath, ["Dock"])
    }
}

import Foundation

/// Launching and locating the *primary* (default-profile) Claude — the untouched
/// real app, distinct from any managed launcher. Kept apart from the launcher CRUD
/// in `ProfileStore` because it deals with the un-managed default profile, and to
/// keep the main file within its length budget.
public extension ProfileStore {
    /// Launch the primary (default-profile) Claude — the untouched real app on its
    /// own built-in user-data-dir, with no `--user-data-dir` override.
    ///
    /// Uses `open -n` to force a *new* instance. Every launcher and the real app run
    /// the same binary at the same path, so LaunchServices identifies them all by one
    /// shared bundle id (`com.anthropic.claudefordesktop`). A plain `open` would find
    /// that id "already running" — as a *clone* — and merely activate it, so the
    /// primary profile would never start (this is the whole point of the workaround).
    /// `-n` sidesteps the de-dup and brings the default profile up fresh even while
    /// clones run. Callers MUST first check `runningDefaultPID` and activate an existing
    /// instance instead: a second `-n` on a live default would run two instances on one
    /// user-data-dir and corrupt its LevelDB.
    func openReal() throws {
        try runner.runChecked(CoreConstants.openPath, ["-n", realClaude.appURL.path])
    }

    /// PID of the running primary (default-profile) instance, or `nil`. The default
    /// profile runs this store's real binary with no `--user-data-dir`, so it is the
    /// main whose `profilePath` is `nil` and whose executable is exactly our real
    /// binary. Matching the binary path keeps another Claude edition (e.g. a Beta
    /// default) from being mistaken for it, and reliably detects our own default so
    /// `openReal` is never asked to spawn a duplicate on the same dir.
    func runningDefaultPID() -> Int32? {
        defaultPID(in: processProbe.allClaudeMains())
    }

    /// The default-profile pid within an already-fetched process sweep. Split from
    /// `runningDefaultPID` so `snapshot` can reuse one `ps` for both the launcher list and the
    /// default status instead of scanning the process table twice per refresh. Module-internal
    /// (`internal`, overriding the `public extension` default): it takes raw `ClaudeInstance`s
    /// and is only ever called from within `ClaudeManagerCore`.
    internal func defaultPID(in mains: [ClaudeInstance]) -> Int32? {
        mains.first { $0.profilePath == nil && $0.isRealClaudeBinary(realClaude) }?.pid
    }

    /// Gracefully stop the running default-profile instance, polling until it exits or the
    /// timeout elapses. Delegates to `stopProcess` like `stop(_:force:)`, differing only in
    /// keying on the default's pid, since the untouched default profile has no `Profile`.
    /// Graceful (SIGTERM) by default — never SIGKILL a possibly-active conversation unless
    /// `force` is explicitly requested.
    @discardableResult
    func stopDefault(
        force: Bool = false,
        pollInterval: TimeInterval = 0.5,
        maxPolls: Int = 20
    ) async -> StopOutcome {
        guard let pid = runningDefaultPID() else { return .notRunning }
        return await stopProcess(pid: pid, force: force, pollInterval: pollInterval, maxPolls: maxPolls) {
            runningDefaultPID() == nil
        }
    }
}

import Foundation

/// Launching and locating the *primary* (default-account) Claude — the untouched
/// real app, distinct from any managed launcher. Kept apart from the launcher CRUD
/// in `ProfileStore` because it deals with the un-managed default account, and to
/// keep the main file within its length budget.
public extension ProfileStore {
    /// Launch the primary (default-account) Claude — the untouched real app on its
    /// own built-in user-data-dir, with no `--user-data-dir` override.
    ///
    /// Uses `open -n` to force a *new* instance. Every launcher and the real app run
    /// the same binary at the same path, so LaunchServices identifies them all by one
    /// shared bundle id (`com.anthropic.claudefordesktop`). A plain `open` would find
    /// that id "already running" — as a *clone* — and merely activate it, so the
    /// primary account would never start (this is the whole point of the workaround).
    /// `-n` sidesteps the de-dup and brings the default account up fresh even while
    /// clones run. Callers MUST first check `runningDefaultPID` and activate an existing
    /// instance instead: a second `-n` on a live default would run two instances on one
    /// user-data-dir and corrupt its LevelDB.
    func openReal() throws {
        try runner.runChecked(CoreConstants.openPath, ["-n", realClaude.appURL.path])
    }

    /// PID of the running primary (default-account) instance, or `nil`. The default
    /// account runs this store's real binary with no `--user-data-dir`, so it is the
    /// main whose `profilePath` is `nil` and whose executable is exactly our real
    /// binary. Matching the binary path keeps another Claude edition (e.g. a Beta
    /// default) from being mistaken for it, and reliably detects our own default so
    /// `openReal` is never asked to spawn a duplicate on the same dir.
    func runningDefaultPID() -> Int32? {
        processProbe.allClaudeMains()
            .first { $0.profilePath == nil && $0.executablePath == realClaude.binaryURL.path }?
            .pid
    }

    /// Gracefully stop the running default-account instance, polling until it exits or the
    /// timeout elapses. Mirrors `stop(_:force:)` but keys on the default's pid, since the
    /// untouched default account has no `Profile`. Graceful (SIGTERM) by default — never
    /// SIGKILL a possibly-active conversation unless `force` is explicitly requested.
    @discardableResult
    func stopDefault(
        force: Bool = false,
        pollInterval: TimeInterval = 0.5,
        maxPolls: Int = 20
    ) async -> StopOutcome {
        guard let pid = runningDefaultPID() else { return .notRunning }
        _ = signalSender(pid, force ? SIGKILL : SIGTERM)
        let interval = Duration.seconds(max(0, pollInterval))
        for _ in 0 ..< maxPolls {
            do {
                try await Task.sleep(for: interval)
            } catch {
                break // cancelled — stop waiting
            }
            if runningDefaultPID() == nil { return .stopped }
        }
        return .stillRunning(pid: pid)
    }
}

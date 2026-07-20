import ClaudeManagerCore

// MARK: - Primary (default-account) Claude

extension AppModel {
    /// Launch or focus the primary (default-account) Claude — the untouched app, apart
    /// from any managed launcher. A running default is focused by exact pid (a plain
    /// relaunch de-dupes onto a *clone*, since all instances share Claude's bundle id);
    /// otherwise `open -n` forces a fresh one — the only reliable way to reach it while
    /// clones run. The untouched app has no `shlock` like a clone's launcher, so
    /// duplicate-avoidance is ours to enforce: `isOpeningReal` blocks concurrent runs, we
    /// `open -n` only when a probe says nothing runs, and — crucially — the guard is held
    /// across a poll until the launched instance is ps-visible, closing the cold-start lag
    /// window a re-click or deep-link forward could otherwise slip a duplicate through (#38).
    func openReal() async {
        guard !launchBlockedByStagedApply() else { return }
        guard realClaude != nil else {
            currentError = AppError(message: locateError ?? "Real Claude.app was not found.")
            return
        }
        guard !isOpeningReal else { return }
        isOpeningReal = true
        defer { isOpeningReal = false }

        if let pid = await runningDefaultPID() {
            // Refresh either way: the row's running state may have been stale (the default was
            // started outside the manager), so after focusing it the dot and the Stop action
            // should reflect that it's running instead of waiting for the next poll.
            if activateApp(pid: pid) { await refresh(); return }
            // Found a pid but it won't resolve (just quit, or not yet registered) —
            // re-probe and only launch when nothing is running, never racing a duplicate.
            if await runningDefaultPID() != nil { await refresh(); return }
        }
        let launched = await perform { store in try store.openReal() } != nil
        // Hold `isOpeningReal` (via the `defer`) until the launched instance is ps-visible,
        // not merely until `open -n` returns. The untouched default has no `shlock` guard, so a
        // second launch — another click, or a deep-link forward — landing in the cold-start lag
        // window would `open -n` a duplicate on its one user-data-dir and corrupt the LevelDB
        // (#38). Polling until the pid is observable makes the guard release on observation,
        // mirroring the deep-link forwarder's launch → poll → release. Skip the wait when the
        // launch didn't fire, so a genuinely failed launch stays immediately retryable.
        if launched { await awaitDefaultVisible() }
        await refresh()
    }

    /// Poll (bounded) until the default-account instance is visible to `ps`, letting
    /// `openReal` hold its launch guard across the cold-start lag. Shares the deep-link
    /// forwarder's cold-launch budget so both launch paths wait the identical window (#38).
    private func awaitDefaultVisible() async {
        for _ in 0 ..< DeepLinkForwarder.coldLaunchPollAttempts {
            if await runningDefaultPID() != nil { return }
            try? await Task.sleep(for: DeepLinkForwarder.coldLaunchPollInterval)
        }
    }

    /// Gracefully stop the running default account (SIGTERM), surfacing a notice if it
    /// refuses to quit — mirroring `stop(_:force:)` for a managed profile. `force` escalates
    /// to SIGKILL for a wedged instance.
    func stopDefaultAccount(force: Bool) async {
        let outcome = await perform { store in await store.stopDefault(force: force) }
        if case let .stillRunning(pid)? = outcome {
            currentError = AppError(
                message: "The default account is still running (pid \(pid)). Try Force Stop."
            )
        }
        await refresh()
    }

    /// Running primary-account pid, or `nil`. `nil` means "not running" — and a `perform`
    /// probe failure flattens to the same `nil`, so the two are indistinguishable here.
    private func runningDefaultPID() async -> Int32? {
        await perform { store in store.runningDefaultPID() }.flatMap(\.self)
    }
}

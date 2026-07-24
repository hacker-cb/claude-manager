import ClaudeManagerCore

// MARK: - Launching & restarting managed profiles

/// The launch entry points for managed (clone) profiles. Grouped here — off `AppModel`'s
/// core file — so all "spawn a Claude process" paths share the staged-update swap guard and
/// the file stays within its length budget. The primary (default) profile's launch lives in
/// `AppModel+PrimaryProfile`; deep-link forwarding in `AppModel+DeepLink`.
extension AppModel {
    func open(_ profile: Profile) async {
        guard !launchBlockedByStagedApply() else { return }
        // A running profile only needs its window raised — activate it by pid instead of
        // relaunching the launcher app, which would flash a transient Dock icon (it
        // starts, self-activates via `activate_existing`, and exits at once). Fall back to
        // a launch (shlock-guarded) when nothing owns the probed pid. Refresh either way,
        // so a list that was stale-as-stopped reflects the profile we just proved running.
        if let pid = await runningPID(for: profile), activateApp(pid: pid) {
            await refresh()
            return
        }
        _ = await perform { store in try store.open(profile) }
        await refresh()
    }

    /// Running pid for a managed profile, or `nil`. `nil` means "not running" — and a
    /// `perform` probe failure flattens to the same `nil`, so the two are indistinguishable
    /// here; the caller treats `nil` as "launch it", the safe reading either way.
    private func runningPID(for profile: Profile) async -> Int32? {
        await perform { store in store.runningPID(for: profile) }.flatMap(\.self)
    }

    /// Quit the running instance and relaunch it — how a live instance moves onto a
    /// freshly-updated Claude (its version is fixed at launch, so only a relaunch
    /// picks up an in-place app update). Graceful stop first; if it won't exit, leave
    /// it running and surface the same notice `stop` does rather than force-killing.
    func restart(_ profile: Profile) async {
        guard !launchBlockedByStagedApply() else { return }
        let outcome = await perform { store in await store.stop(profile, force: false) }
        switch outcome {
        case .stopped?, .notRunning?:
            _ = await perform { store in try store.open(profile) }
        case let .stillRunning(pid)?:
            currentError = AppError(
                message: "\(profile.displayName) is still running (pid \(pid)). Try Force Stop, then Open."
            )
        case nil:
            break // perform already surfaced the failure
        }
        await refresh()
    }
}

import Foundation

/// Outcome of `rebuildAll`: which launchers were regenerated, which were skipped
/// because they were running (a live bundle can't be rewritten), and which failed
/// (e.g. an icon-pipeline error, or a bundle removed mid-batch) — a single bad
/// launcher never aborts the rest.
public struct RebuildAllResult: Sendable {
    /// A launcher the batch could not rebuild, together with **why** — the reason is
    /// carried, not dropped: a signing failure (the one that makes a launcher
    /// unrunnable) is otherwise indistinguishable from an icon-pipeline hiccup, and the
    /// user is left retrying Rebuild All against an error nothing ever names.
    public struct Failure: Sendable {
        public let profile: Profile
        public let reason: String

        public init(profile: Profile, reason: String) {
            self.profile = profile
            self.reason = reason
        }
    }

    public let rebuilt: [Profile]
    public let skippedRunning: [Profile]
    public let failed: [Failure]
    /// True when at least one rebuilt launcher's icon actually changed, so a pinned Dock
    /// tile could be stale and the app may offer an opt-in "Refresh Dock now". A batch that
    /// only re-stamped the wrapper format (icons byte-identical) leaves this false.
    public let dockRefreshPending: Bool
}

/// Regenerating launchers from the current wrapper format — one at a time or as a
/// batch. Split out of `ProfileStore` to keep that file within its length budget.
public extension ProfileStore {
    /// Rebuild one launcher end-to-end from the current wrapper format — its bash
    /// script (freshly stamped with the real-binary path and `currentWrapperVersion`),
    /// its Info.plist marker, and its badge icon (rendered with the current style).
    /// This is how a stale launcher is brought up to date and how the user forces a
    /// fresh regenerate. Refuses while the profile is running: rewriting the bundle
    /// under a live instance is unsafe (the same reason `update` refuses). Returns whether
    /// the icon actually changed — `rebuild` is always in-place, so a changed icon means a
    /// pinned Dock tile could be stale (the app offers an opt-in refresh); an unchanged one
    /// (a wrapper-format bump, the common case) needs no refresh and never flashes.
    @discardableResult
    func rebuild(_ profile: Profile) throws -> Bool {
        try ensureRealBinaryPresent()
        guard fileManager.fileExists(atPath: profile.appPath) else {
            throw ClaudeManagerError.launcherNotFound(name: profile.name)
        }
        if let pid = runningPID(for: profile) {
            throw ClaudeManagerError.profileRunning(name: profile.name, pid: pid)
        }
        let icns = try iconPipeline.makeBadgeICNS(
            realClaude: realClaude,
            label: profile.label,
            color: profile.color,
            style: configuration.badgeStyle
        )
        let iconChanged = try bundle.build(
            profile: profile, realBinaryPath: realClaude.binaryURL.path, icnsData: icns
        )
        // Register so the new icon is picked up on next fetch/open — never flash the
        // screen (see `IconCache`).
        iconCache.register(appURL: profile.appURL)
        // Re-seed the overlay alongside the wrapper refresh (best-effort — a config
        // hiccup must not fail the rebuild). Covers `rebuildAll`'s rebuilt launchers too.
        try? reconcileManagedConfig(for: profile)
        return iconChanged
    }

    /// Rebuild every launcher (see `rebuild`). A running launcher is *skipped*, not failed
    /// — a live bundle can't be rewritten — and returned so the caller can report it. Never
    /// restarts the Dock: the batch reports whether any icon changed (`dockRefreshPending`)
    /// so the app can offer a single opt-in refresh instead of flashing the screen.
    @discardableResult
    func rebuildAll() throws -> RebuildAllResult {
        try ensureRealBinaryPresent()
        var rebuilt: [Profile] = []
        var skippedRunning: [Profile] = []
        var failed: [RebuildAllResult.Failure] = []
        var dockRefreshPending = false
        for managed in list() {
            if managed.isRunning {
                skippedRunning.append(managed.profile)
                continue
            }
            do {
                let iconChanged = try rebuild(managed.profile)
                rebuilt.append(managed.profile)
                if iconChanged { dockRefreshPending = true }
            } catch ClaudeManagerError.profileRunning {
                // Started between the scan and the rebuild — skip it too.
                skippedRunning.append(managed.profile)
            } catch {
                // A single launcher's failure (icon pipeline, signing, bundle vanished
                // mid-batch, …) must not abort the rest — record it *with its reason*
                // and continue, so the batch report can say what actually went wrong.
                failed.append(RebuildAllResult.Failure(
                    profile: managed.profile,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                ))
            }
        }
        // No automatic Dock restart — a rebuild never flashes the screen. When an icon
        // actually changed, the app surfaces an opt-in "Refresh Dock now"; otherwise the
        // pinned tiles self-heal the next time each launcher is opened.
        // `rebuild` already seeded each rebuilt clone; seed the skipped-running ones too
        // (harmless while live — read at next launch). No extra scan: reuse the sets.
        for profile in skippedRunning {
            try? reconcileManagedConfig(for: profile)
        }
        return RebuildAllResult(
            rebuilt: rebuilt, skippedRunning: skippedRunning, failed: failed,
            dockRefreshPending: dockRefreshPending
        )
    }
}

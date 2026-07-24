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
}

/// Regenerating launchers from the current wrapper format — one at a time or as a
/// batch. Split out of `ProfileStore` to keep that file within its length budget.
public extension ProfileStore {
    /// Rebuild one launcher end-to-end from the current wrapper format — its bash
    /// script (freshly stamped with the real-binary path and `currentWrapperVersion`),
    /// its Info.plist marker, and its badge icon (rendered with the current style).
    /// This is how a stale launcher is brought up to date and how the user forces a
    /// fresh regenerate. Refuses while the profile is running: rewriting the bundle
    /// under a live instance is unsafe (the same reason `update` refuses).
    func rebuild(_ profile: Profile, restartDock: Bool = true) throws {
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
        try bundle.build(profile: profile, realBinaryPath: realClaude.binaryURL.path, icnsData: icns)
        iconCache.refresh(appURL: profile.appURL, restartDock: restartDock)
        // Re-seed the overlay alongside the wrapper refresh (best-effort — a config
        // hiccup must not fail the rebuild). Covers `rebuildAll`'s rebuilt launchers too.
        try? reconcileManagedConfig(for: profile)
    }

    /// Rebuild every launcher (see `rebuild`), restarting the Dock once for the
    /// batch. A running launcher is *skipped*, not failed — a live bundle can't be
    /// rewritten — and returned so the caller can report it.
    @discardableResult
    func rebuildAll() throws -> RebuildAllResult {
        try ensureRealBinaryPresent()
        var rebuilt: [Profile] = []
        var skippedRunning: [Profile] = []
        var failed: [RebuildAllResult.Failure] = []
        for managed in list() {
            if managed.isRunning {
                skippedRunning.append(managed.profile)
                continue
            }
            do {
                try rebuild(managed.profile, restartDock: false)
                rebuilt.append(managed.profile)
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
        if !rebuilt.isEmpty { iconCache.restartDock() }
        // `rebuild` already seeded each rebuilt clone; seed the skipped-running ones too
        // (harmless while live — read at next launch). No extra scan: reuse the sets.
        for profile in skippedRunning {
            try? reconcileManagedConfig(for: profile)
        }
        return RebuildAllResult(rebuilt: rebuilt, skippedRunning: skippedRunning, failed: failed)
    }
}

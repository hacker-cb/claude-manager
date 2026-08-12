import Foundation

/// Outcome of one launcher's rebuild.
public struct RebuildResult: Sendable {
    /// True when the badge this rebuild wrote differs from the one installed — see
    /// `AddResult.dockRefreshPending`, whose contract this feeds.
    public let iconChanged: Bool
    /// Set when the launcher was rebuilt under a live instance — see `LiveRewrite`.
    public let liveRewrite: LiveRewrite?

    public init(iconChanged: Bool, liveRewrite: LiveRewrite?) {
        self.iconChanged = iconChanged
        self.liveRewrite = liveRewrite
    }
}

/// Outcome of `rebuildAll`: which launchers were regenerated, which of them were rewritten
/// under a live instance and so need a restart to show it, and which failed (e.g. an
/// icon-pipeline error, or a bundle removed mid-batch) — a single bad launcher never aborts
/// the rest. Nothing is skipped for running any more: a running launcher is rebuilt like
/// every other and simply reported in `liveRewrites`.
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
    /// The subset of `rebuilt` whose instance was live *and* whose badge actually changed —
    /// each needs a restart before the new badge reaches the running window. A rebuild
    /// regenerates from the bundle's own marker, so it can never change the window's name;
    /// only an edit can.
    public let liveRewrites: [LiveRewrite]
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
    /// fresh regenerate.
    ///
    /// Runs while the profile is running, reporting it through `RebuildResult.liveRewrite`
    /// instead of refusing — the reasoning is `LiveRewrite`'s. Refusing here would be worse
    /// than merely inconvenient: a wrapper-version bump makes *every* launcher stale at
    /// once, and the rebuild is how the new format reaches them, so a guard would put the
    /// fix out of reach of exactly the profiles someone keeps open all day.
    ///
    /// Reports whether the icon actually changed — `rebuild` is always in-place, so a
    /// changed icon means a pinned Dock tile could be stale (the app offers an opt-in
    /// refresh); an unchanged one (a wrapper-format bump, the common case) needs no refresh
    /// and never flashes.
    @discardableResult
    func rebuild(_ profile: Profile) throws -> RebuildResult {
        try ensureRealBinaryPresent()
        guard fileManager.fileExists(atPath: profile.appPath) else {
            throw ClaudeManagerError.launcherNotFound(name: profile.name)
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
        // hiccup must not fail the rebuild). Covers `rebuildAll`'s rebuilt launchers too,
        // and is harmless under a live instance: the clone reads it at next launch.
        try? reconcileManagedConfig(for: profile)
        // A rebuild regenerates from the bundle's own marker, so it cannot change the name a
        // running window shows — the badge is the only thing a restart could reveal, and
        // only when it actually changed. See `liveRewrite(for:presentationChanged:)`, which
        // also explains why the pid is sampled here rather than before the swap.
        return RebuildResult(
            iconChanged: iconChanged,
            liveRewrite: liveRewrite(for: profile, presentationChanged: iconChanged)
        )
    }

    /// Rebuild every launcher (see `rebuild`). Running ones are rebuilt too and reported in
    /// `liveRewrites` so the app can nudge each for a restart — skipping them would leave a
    /// wrapper bump undelivered to whichever profiles the user keeps open. Never restarts
    /// the Dock: the batch reports whether any icon changed (`dockRefreshPending`) so the
    /// app can offer a single opt-in refresh instead of flashing the screen.
    @discardableResult
    func rebuildAll() throws -> RebuildAllResult {
        try ensureRealBinaryPresent()
        var rebuilt: [Profile] = []
        var liveRewrites: [LiveRewrite] = []
        var failed: [RebuildAllResult.Failure] = []
        var dockRefreshPending = false
        // `scan`, not `list()`: the batch rebuilds every launcher regardless of state, so the
        // full `ps` sweep and per-launcher `pgrep` that `list()` runs to fill in running
        // state and versions would be paid for and thrown away. It was needed while running
        // launchers were skipped; `rebuild` still probes for itself, once, after its swap.
        for profile in bundle.scan(installDirectory: configuration.installDirectory).map(\.profile) {
            do {
                let result = try rebuild(profile)
                rebuilt.append(profile)
                if let live = result.liveRewrite { liveRewrites.append(live) }
                if result.iconChanged { dockRefreshPending = true }
            } catch {
                // A single launcher's failure (icon pipeline, signing, bundle vanished
                // mid-batch, …) must not abort the rest — record it *with its reason*
                // and continue, so the batch report can say what actually went wrong.
                failed.append(RebuildAllResult.Failure(
                    profile: profile,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                ))
                // Still seed the overlay. `rebuild` reconciles only after a successful
                // build, so without this a batch on a machine where the icon pipeline or
                // signing is broken reconciles *nothing* — and a clone left without its
                // overlay lets Claude's own updater run inside it. The batch used to
                // guarantee this for every launcher it touched; keep that guarantee.
                try? reconcileManagedConfig(for: profile)
            }
        }
        // No automatic Dock restart — a rebuild never flashes the screen. When an icon
        // actually changed, the app surfaces an opt-in "Refresh Dock now"; when none did,
        // no pinned tile can be showing anything but the icon already installed.
        return RebuildAllResult(
            rebuilt: rebuilt, liveRewrites: liveRewrites, failed: failed,
            dockRefreshPending: dockRefreshPending
        )
    }
}

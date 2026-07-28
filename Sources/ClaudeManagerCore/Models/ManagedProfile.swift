import Foundation

/// A `Profile` decorated with live runtime state for display in the manager.
public struct ManagedProfile: Identifiable, Equatable, Sendable {
    public let profile: Profile
    /// PID of the running main process for this profile, or `nil` if stopped.
    public let pid: Int32?
    /// Human-readable disk usage of the profile dir (e.g. `1.2G`), if measured.
    public let diskSize: String?
    /// Wrapper version stamped into this launcher's marker at build time.
    public let wrapperVersion: Int
    /// Marketing version the live instance is running (`nil` when stopped or unknown).
    public let runningClaudeVersion: String?
    /// Current on-disk version of the real Claude.app this launcher wraps.
    public let availableClaudeVersion: String?

    public init(
        profile: Profile,
        pid: Int32?,
        diskSize: String? = nil,
        wrapperVersion: Int = CoreConstants.currentWrapperVersion,
        runningClaudeVersion: String? = nil,
        availableClaudeVersion: String? = nil
    ) {
        self.profile = profile
        self.pid = pid
        self.diskSize = diskSize
        self.wrapperVersion = wrapperVersion
        self.runningClaudeVersion = runningClaudeVersion
        self.availableClaudeVersion = availableClaudeVersion
    }

    public var id: String {
        profile.id
    }

    public var isRunning: Bool {
        pid != nil
    }

    /// True when the launcher was built by an older wrapper than the current one —
    /// the app surfaces this as "update available" and offers a rebuild.
    public var needsRebuild: Bool {
        CoreConstants.wrapperVersionIsStale(wrapperVersion)
    }

    /// True when this launcher predates ad-hoc signing, so macOS refuses to execute it:
    /// it flashes in the Dock and dies. A subset of `needsRebuild` that the app must
    /// word as a failure, not as an optional improvement — the rebuild is mandatory.
    public var isUnrunnable: Bool {
        CoreConstants.wrapperVersionIsUnrunnable(wrapperVersion)
    }

    /// True when the live instance is running an older Claude than the one now on
    /// disk — Claude.app updated in place while this instance kept its launch-time
    /// version. Distinct from `needsRebuild`: the fix is a restart, not a rebuild.
    public var claudeUpdateAvailable: Bool {
        guard isRunning,
              let running = runningClaudeVersion,
              let available = availableClaudeVersion
        else { return false }
        return VersionOrder.isNewer(available, than: running)
    }

    /// The one launcher condition a compact surface flags, or nil when there's nothing to say.
    ///
    /// The precedence is load-bearing, not cosmetic: `isUnrunnable` is a *subset* of
    /// `needsRebuild`, so an unsigned launcher satisfies both and the wrong order would word a
    /// hard failure ("won't launch") as the optional nudge it isn't. A restart-to-update comes
    /// last — it's the only one of the three that isn't about the launcher being broken.
    public var attention: LauncherAttention? {
        if isUnrunnable { return .unrunnable }
        if needsRebuild { return .rebuildAvailable }
        if claudeUpdateAvailable { return .claudeUpdate(version: availableClaudeVersion) }
        return nil
    }
}

/// What a launcher needs from the user, as one value — so a row that has room for a single mark
/// picks the same one everywhere instead of re-deriving the precedence per surface.
public enum LauncherAttention: Equatable, Sendable {
    /// macOS refuses to execute this launcher (built before ad-hoc signing) — a rebuild is
    /// mandatory, not optional.
    case unrunnable
    /// Built by an older wrapper: it still runs, but a rebuild brings it current.
    case rebuildAvailable
    /// The running instance is behind the Claude.app on disk — fixed by a restart, not a rebuild.
    case claudeUpdate(version: String?)
}

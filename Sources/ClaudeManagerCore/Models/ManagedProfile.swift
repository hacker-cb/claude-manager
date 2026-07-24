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
}

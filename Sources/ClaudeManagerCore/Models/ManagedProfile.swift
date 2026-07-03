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

    public init(
        profile: Profile,
        pid: Int32?,
        diskSize: String? = nil,
        wrapperVersion: Int = CoreConstants.currentWrapperVersion
    ) {
        self.profile = profile
        self.pid = pid
        self.diskSize = diskSize
        self.wrapperVersion = wrapperVersion
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
}

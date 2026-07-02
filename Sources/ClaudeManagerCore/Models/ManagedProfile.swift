import Foundation

/// A `Profile` decorated with live runtime state for display in the manager.
public struct ManagedProfile: Identifiable, Equatable, Sendable {
    public let profile: Profile
    /// PID of the running main process for this profile, or `nil` if stopped.
    public let pid: Int32?
    /// Human-readable disk usage of the profile dir (e.g. `1.2G`), if measured.
    public let diskSize: String?

    public init(profile: Profile, pid: Int32?, diskSize: String? = nil) {
        self.profile = profile
        self.pid = pid
        self.diskSize = diskSize
    }

    public var id: String {
        profile.id
    }

    public var isRunning: Bool {
        pid != nil
    }
}

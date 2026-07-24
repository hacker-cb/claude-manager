import Foundation

/// The profile state a single `refresh` needs, gathered from one process sweep: every managed
/// launcher plus the default profile's status. Bundling them lets `ProfileStore.snapshot`
/// scan the process table once instead of `list` and the default-pid probe each scanning it.
public struct StoreSnapshot: Equatable, Sendable {
    public let profiles: [ManagedProfile]
    public let primaryProfile: PrimaryProfileStatus

    public init(profiles: [ManagedProfile], primaryProfile: PrimaryProfileStatus) {
        self.profiles = profiles
        self.primaryProfile = primaryProfile
    }
}

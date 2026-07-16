import Foundation

/// The account state a single `refresh` needs, gathered from one process sweep: every managed
/// launcher plus the default account's status. Bundling them lets `ProfileStore.snapshot`
/// scan the process table once instead of `list` and the default-pid probe each scanning it.
public struct StoreSnapshot: Equatable, Sendable {
    public let profiles: [ManagedProfile]
    public let primaryAccount: PrimaryAccountStatus

    public init(profiles: [ManagedProfile], primaryAccount: PrimaryAccountStatus) {
        self.profiles = profiles
        self.primaryAccount = primaryAccount
    }
}

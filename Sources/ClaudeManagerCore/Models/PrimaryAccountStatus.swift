import Foundation

/// Observable state of the *primary* (default-account) Claude — the untouched real app run
/// without a launcher. Unlike a `ManagedProfile`, the default account has no launcher bundle,
/// so it carries only what the account lists need to render it as a peer row: whether it is
/// running (and, for the "Running (pid N)" label, which pid). The on-disk Claude version is
/// already published as `AppModel.realClaudeVersion`, so it is deliberately *not* duplicated
/// here.
public struct PrimaryAccountStatus: Equatable, Sendable {
    /// PID of the running default-account instance, or `nil` when it is not running.
    public let pid: Int32?

    public init(pid: Int32?) {
        self.pid = pid
    }

    public var isRunning: Bool {
        pid != nil
    }
}

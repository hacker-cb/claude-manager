import Foundation

/// How current an account's usage data is — drives the honest UI states (fresh vs stale vs a
/// reason we're not fetching). Every non-`fresh` case still carries whatever snapshot the
/// store had, so the UI shows the last known numbers rather than blanking.
public enum UsageState: Sendable, Equatable {
    /// Just fetched.
    case fresh
    /// Serving the last stored sample, captured at this time (offline / throttled / skipped).
    case stale(since: Date)
    /// Token expired or the API rejected it (401/403) — the account needs a fresh login.
    case loginNeeded
    /// Backed off after a 429 until this time (nil if the server gave no Retry-After).
    case rateLimited(until: Date?)
    /// No usable token source (keychain locked / not authorized, or no token cache).
    case noSource
    /// A transport failure (offline); the snapshot, if any, is the last stored one.
    case offline
}

/// One account's usage as published to the UI: its identity, the freshest snapshot available
/// (fresh or stale), the state explaining that, and every binding that maps to it (for
/// "shared with N profiles").
public struct AccountUsage: Sendable, Equatable {
    public var identity: AccountIdentity
    public var snapshot: UsageSnapshot?
    public var state: UsageState
    public var bindingIDs: [String]

    public init(
        identity: AccountIdentity,
        snapshot: UsageSnapshot?,
        state: UsageState,
        bindingIDs: [String]
    ) {
        self.identity = identity
        self.snapshot = snapshot
        self.state = state
        self.bindingIDs = bindingIDs
    }
}

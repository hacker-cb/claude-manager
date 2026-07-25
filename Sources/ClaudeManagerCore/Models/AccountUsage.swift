import Foundation

/// How current an account's usage data is — drives the honest UI states (fresh vs stale vs a
/// reason we're not fetching). Every non-`fresh` case still carries whatever snapshot the
/// store had, so the UI shows the last known numbers rather than blanking.
public enum UsageState: Sendable, Equatable {
    /// The newest values we have: either just fetched, or re-served within the per-account floor
    /// because there was no reason to ask again. `snapshot.capturedAt` carries the age either way.
    case fresh
    /// Serving the last stored sample because a refresh genuinely couldn't happen — offline, or
    /// inside an error backoff. Reserved for that: a deliberate skip is not staleness.
    case stale(since: Date)
    /// Token expired or the API rejected it (401/403) — the account needs a fresh login.
    case loginNeeded
    /// Backed off after a 429 on the `/usage` read — a *request* throttle ("not your usage limit"),
    /// not plan exhaustion (that shows as the bars' own data, never as a 429). A pure discriminator:
    /// when to retry lives in `ThrottleState.backoffUntil` (its single source of truth), and the UI
    /// deliberately doesn't surface the backoff timing — it's an internal poll concern.
    case rateLimited
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

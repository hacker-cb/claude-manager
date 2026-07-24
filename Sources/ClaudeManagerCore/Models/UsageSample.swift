import Foundation

/// One persisted usage observation for an account: the full snapshot (the canonical restore
/// source), when it was captured, and which binding it came from. The flat index columns the
/// store also writes are derived from `snapshot`, not carried here.
public struct UsageSample: Sendable, Equatable {
    public var accountUUID: String
    public var capturedAt: Date
    public var snapshot: UsageSnapshot
    /// Present-day provenance — `desktop:<binding>` (later `cli:<configdir>`). Lets the UI and
    /// future analysis attribute a sample without re-deriving it.
    public var source: String

    public init(accountUUID: String, capturedAt: Date, snapshot: UsageSnapshot, source: String) {
        self.accountUUID = accountUUID
        self.capturedAt = capturedAt
        self.snapshot = snapshot
        self.source = source
    }
}

/// Why a poll is currently backed off — persisted so a *subsequent* tick renders the honest
/// state (a transport failure must not read back as a 429). `terminal` parks the account until
/// the token fingerprint changes (a 401/403 re-login).
public enum BackoffReason: String, Sendable, Equatable {
    case rateLimited
    case offline
    case terminal
}

/// Durable per-account throttle state, read back each poll tick so the 60s floor, the backoff
/// window (and its cause), and the token-fingerprint cache survive the stateless-per-refresh
/// `UsageService` (which owns no memory of its own between ticks).
public struct ThrottleState: Sendable, Equatable {
    public var lastAttemptAt: Date?
    public var backoffUntil: Date?
    public var backoffReason: BackoffReason?
    /// `sha256(token)[:16]` — a login switch changes it, invalidating the cache immediately.
    public var tokenFingerprint: String?

    public init(
        lastAttemptAt: Date? = nil,
        backoffUntil: Date? = nil,
        backoffReason: BackoffReason? = nil,
        tokenFingerprint: String? = nil
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.backoffUntil = backoffUntil
        self.backoffReason = backoffReason
        self.tokenFingerprint = tokenFingerprint
    }
}

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

/// Durable per-account throttle state, read back each poll tick so the 60s floor, the 429
/// backoff window, and the token-fingerprint cache survive the stateless-per-refresh
/// `UsageService` (which owns no memory of its own between ticks).
public struct ThrottleState: Sendable, Equatable {
    public var lastAttemptAt: Date?
    public var backoffUntil: Date?
    /// `sha256(token)[:16]` — a login switch changes it, invalidating the cache immediately.
    public var tokenFingerprint: String?

    public init(lastAttemptAt: Date? = nil, backoffUntil: Date? = nil, tokenFingerprint: String? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.backoffUntil = backoffUntil
        self.tokenFingerprint = tokenFingerprint
    }
}

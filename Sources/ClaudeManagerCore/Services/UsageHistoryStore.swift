import Foundation
import SQLite3

/// Owns the `sqlite3` handle and closes it on `deinit`. A class (not the actor) so closing
/// happens in the holder's own deinit — Swift 6 forbids an actor's nonisolated deinit from
/// touching its non-`Sendable` stored handle. `@unchecked Sendable` is sound because the
/// handle is only ever used inside the actor's serialized methods, and this deinit runs only
/// once the actor (and thus this holder) is released — after every method call has finished.
private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer?
    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    deinit { if let handle { sqlite3_close(handle) } }
}

/// The plan-usage history + throttle + notification-ledger store, backed by one serialized
/// `sqlite3` connection. An `actor` because a poll-write, a UI serve-stale read, and a
/// notification check all touch the same connection, and macOS `libsqlite3` is thread-safe
/// only per-connection.
///
/// **Degrade-not-crash** (mirrors `MetadataStore`): if the DB can't be opened, every method
/// no-ops or returns empty — usage still works from a fresh fetch, just without history. The
/// schema is a *cache*, not a contract: on any `user_version` mismatch the tables are dropped
/// and recreated (early-stage — no migrations to maintain).
///
/// The SQLite primitives are `static` (nonisolated) helpers over an explicit handle, so opening
/// and bootstrapping needs no actor-isolated state; the actor only serializes access to the `db`
/// handle it holds.
public actor UsageHistoryStore {
    private let path: String
    private var connection: SQLiteConnection?

    /// Opens on **first use**, on the actor's own executor — never on the caller's thread.
    /// `AppModel` builds this store from its `init` on the main actor, and opening there would
    /// block the first frame: `sqlite3_open_v2` plus the bootstrap PRAGMAs, and on a schema bump
    /// a full DROP/CREATE/VACUUM that can take seconds over a large history.
    ///
    /// A failed open is remembered as a connection with a nil handle rather than retried on every
    /// call, so a broken path degrades once (to the in-memory fallbacks) instead of thrashing.
    private var db: OpaquePointer? {
        if let connection { return connection.handle }
        let opened = SQLiteConnection(handle: Self.open(path: path))
        connection = opened
        return opened.handle
    }

    /// In-memory fallbacks used **only when the DB can't be opened**. History (samples) is
    /// genuinely optional and degrades to empty, but the throttle state and the notification
    /// ledger are not: losing the throttle would strip `UsageService`'s 60s floor and 429
    /// backoff and hammer the API, and losing the ledger would re-notify every tick. These keep
    /// both working for the session (just not persisted across restarts).
    private var memoryThrottle: [String: ThrottleState] = [:]
    private var memoryNotified: Set<String> = []
    /// Same idea for the identity cache: without it a dead DB would re-fetch `/profile` on every
    /// tick instead of once a day.
    private var memoryProfiles: [String: (identity: AccountIdentity, fetchedAt: Date)] = [:]

    /// Note the store at `path`; the file is opened and bootstrapped on the first call that needs
    /// it, not here. Pass `":memory:"` for a throwaway store in tests. A failed open leaves the
    /// store inert (every method no-ops / returns empty); the handle is closed by
    /// `SQLiteConnection.deinit` when the store is released.
    public init(path: String) {
        self.path = path
    }

    // MARK: - Samples

    /// Record a sample. `snapshot_json` is the canonical restore source; the flat columns are a
    /// denormalized index; `raw_json` is kept for the inspector but **only on the latest sample
    /// per account** (older rows' raw is cleared to bound growth).
    public func record(_ sample: UsageSample, rawBody: Data?) {
        guard let db else { return }
        guard let snapshotJSON = Self.encodeSnapshot(sample.snapshot) else { return }

        // The insert + the raw-cleanup are one transaction so a crash can't leave raw cleared
        // with no new row.
        _ = Self.exec(db, "BEGIN")
        let sql = """
        INSERT INTO usage_samples
        (account_uuid, captured_at, five_hour_frac, seven_day_frac, binding_frac,
         extra_used_minor, extra_limit_minor, severity, snapshot_json, raw_json, source)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
        """
        if let stmt = Self.prepare(db, sql) {
            Self.bind(stmt, 1, text: sample.accountUUID)
            Self.bind(stmt, 2, int: Self.millis(sample.capturedAt))
            Self.bind(stmt, 3, double: sample.snapshot.session?.utilization)
            Self.bind(stmt, 4, double: sample.snapshot.weeklyAll?.utilization)
            Self.bind(stmt, 5, double: sample.snapshot.bindingLimit?.utilization)
            Self.bind(stmt, 6, int: sample.snapshot.extra.map { Int64($0.usedMinor) })
            Self.bind(stmt, 7, int: sample.snapshot.extra?.limitMinor.map(Int64.init))
            Self.bind(stmt, 8, text: sample.snapshot.bindingLimit?.severity.rawValue)
            Self.bind(stmt, 9, text: snapshotJSON)
            Self.bind(stmt, 10, text: rawBody.flatMap { String(data: $0, encoding: .utf8) })
            Self.bind(stmt, 11, text: sample.source)
            Self.step(stmt)
        }
        // Keep raw_json only on the account's newest row — computed *after* insert (against the
        // real max captured_at), so an out-of-order sample can't desync latest() from
        // latestRawJSON().
        if let stmt = Self.prepare(db, """
        UPDATE usage_samples SET raw_json=NULL
        WHERE account_uuid=?1
          AND captured_at < (SELECT MAX(captured_at) FROM usage_samples WHERE account_uuid=?1)
        """) {
            Self.bind(stmt, 1, text: sample.accountUUID)
            Self.step(stmt)
        }
        _ = Self.exec(db, "COMMIT")
    }

    /// The most recent sample for an account (for serve-stale), or nil.
    public func latest(accountUUID: String) -> UsageSample? {
        guard let db else { return nil }
        let sql = """
        SELECT captured_at, snapshot_json, source FROM usage_samples
        WHERE account_uuid=?1 ORDER BY captured_at DESC LIMIT 1
        """
        guard let stmt = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let json = Self.text(stmt, 1), let snapshot = Self.decodeSnapshot(json) else { return nil }
        return UsageSample(
            accountUUID: accountUUID,
            capturedAt: Self.date(fromMillis: sqlite3_column_int64(stmt, 0)),
            snapshot: snapshot,
            source: Self.text(stmt, 2) ?? ""
        )
    }

    /// The raw `/usage` JSON for the account's latest sample — for the Doctor inspector.
    public func latestRawJSON(accountUUID: String) -> String? {
        guard let db else { return nil }
        let sql = """
        SELECT raw_json FROM usage_samples
        WHERE account_uuid=?1 AND raw_json IS NOT NULL ORDER BY captured_at DESC LIMIT 1
        """
        guard let stmt = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.text(stmt, 0)
    }

    /// Sample count for an account (test / introspection helper).
    public func sampleCount(accountUUID: String) -> Int {
        guard let db else { return 0 }
        guard let stmt = Self.prepare(db, "SELECT COUNT(*) FROM usage_samples WHERE account_uuid=?1")
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Throttle state

    public func throttle(scope: String) -> ThrottleState? {
        guard let db else { return memoryThrottle[scope] }
        let sql = """
        SELECT last_attempt_at, backoff_until, backoff_reason, token_fingerprint
        FROM throttle_state WHERE scope_key=?1
        """
        guard let stmt = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: scope)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ThrottleState(
            lastAttemptAt: Self.optionalDate(stmt, 0),
            backoffUntil: Self.optionalDate(stmt, 1),
            backoffReason: Self.text(stmt, 2).flatMap(BackoffReason.init(rawValue:)),
            tokenFingerprint: Self.text(stmt, 3)
        )
    }

    public func setThrottle(_ state: ThrottleState, scope: String) {
        guard let db else { memoryThrottle[scope] = state; return }
        let sql = """
        INSERT INTO throttle_state (scope_key, last_attempt_at, backoff_until, backoff_reason, token_fingerprint)
        VALUES (?1,?2,?3,?4,?5)
        ON CONFLICT(scope_key) DO UPDATE SET
            last_attempt_at=excluded.last_attempt_at,
            backoff_until=excluded.backoff_until,
            backoff_reason=excluded.backoff_reason,
            token_fingerprint=excluded.token_fingerprint
        """
        guard let stmt = Self.prepare(db, sql) else { return }
        Self.bind(stmt, 1, text: scope)
        Self.bind(stmt, 2, int: state.lastAttemptAt.map(Self.millis))
        Self.bind(stmt, 3, int: state.backoffUntil.map(Self.millis))
        Self.bind(stmt, 4, text: state.backoffReason?.rawValue)
        Self.bind(stmt, 5, text: state.tokenFingerprint)
        Self.step(stmt)
    }

    // MARK: - Notification dedup ledger (used in the notifications slice)

    public func wasNotified(
        accountUUID: String,
        limitKey: String,
        threshold: Double,
        resetsAt: Date?
    ) -> Bool {
        let threshold = Self.roundedThreshold(threshold)
        guard let db else {
            return memoryNotified.contains(Self.notifiedKey(accountUUID, limitKey, threshold, resetsAt))
        }
        let sql = """
        SELECT 1 FROM notified_thresholds
        WHERE account_uuid=?1 AND limit_key=?2 AND threshold=?3 AND resets_at=?4 LIMIT 1
        """
        guard let stmt = Self.prepare(db, sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        Self.bind(stmt, 2, text: limitKey)
        Self.bind(stmt, 3, double: threshold)
        Self.bind(stmt, 4, int: resetsAt.map(Self.millis) ?? 0)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func markNotified(
        accountUUID: String,
        limitKey: String,
        threshold: Double,
        resetsAt: Date?,
        notifiedAt: Date
    ) {
        let threshold = Self.roundedThreshold(threshold)
        guard let db else {
            memoryNotified.insert(Self.notifiedKey(accountUUID, limitKey, threshold, resetsAt))
            return
        }
        let sql = """
        INSERT OR REPLACE INTO notified_thresholds
        (account_uuid, limit_key, threshold, resets_at, notified_at) VALUES (?1,?2,?3,?4,?5)
        """
        guard let stmt = Self.prepare(db, sql) else { return }
        Self.bind(stmt, 1, text: accountUUID)
        Self.bind(stmt, 2, text: limitKey)
        Self.bind(stmt, 3, double: threshold)
        Self.bind(stmt, 4, int: resetsAt.map(Self.millis) ?? 0)
        Self.bind(stmt, 5, int: Self.millis(notifiedAt))
        Self.step(stmt)
    }

    /// Round the threshold so ledger writes and checks match on a stable value — the tiers are
    /// constants today, but this guards against a future computed threshold whose last float bit
    /// differs (a `REAL =` miss would re-notify).
    private static func roundedThreshold(_ threshold: Double) -> Double {
        (threshold * 1_000_000).rounded() / 1_000_000
    }

    private static func notifiedKey(
        _ uuid: String,
        _ limitKey: String,
        _ threshold: Double,
        _ resetsAt: Date?
    ) -> String {
        "\(uuid)|\(limitKey)|\(threshold)|\(resetsAt.map(millis) ?? 0)"
    }

    // MARK: - Account profile (identity cache)

    /// The `/profile` answer for a token, if one was stored **and fetched no earlier than**
    /// `fetchedAfter`. Keyed by the token's fingerprint, so a re-login simply misses and
    /// re-fetches; the freshness bound then covers what can change without a new token — a
    /// renamed account, a changed email, a moved plan.
    public func profile(tokenFingerprint: String, fetchedAfter: Date) -> AccountIdentity? {
        guard let db else {
            guard let cached = memoryProfiles[tokenFingerprint], cached.fetchedAt >= fetchedAfter else {
                return nil
            }
            return cached.identity
        }
        let sql = """
        SELECT account_uuid, email, display_name, organization_uuid, subscription_type, rate_limit_tier
        FROM account_profiles WHERE token_fingerprint=?1 AND fetched_at>=?2 LIMIT 1
        """
        return readProfile(sql) { stmt in
            Self.bind(stmt, 1, text: tokenFingerprint)
            Self.bind(stmt, 2, int: Self.millis(fetchedAfter))
        }
    }

    /// Run a prepared `account_profiles` SELECT (both lookups share the column list) and decode
    /// the row into an identity.
    private func readProfile(_ sql: String, bind: (OpaquePointer) -> Void) -> AccountIdentity? {
        guard let db, let stmt = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW, let uuid = Self.text(stmt, 0) else { return nil }
        return AccountIdentity(
            uuid: uuid,
            email: Self.text(stmt, 1),
            displayName: Self.text(stmt, 2),
            organizationUuid: Self.text(stmt, 3),
            subscriptionType: Self.text(stmt, 4),
            rateLimitTier: Self.text(stmt, 5)
        )
    }

    /// The stored `/profile` answer for an **account**, whichever token fetched it.
    ///
    /// The name is a property of the account, not of the token that asked, so N launchers sharing
    /// one login should cost one lookup rather than one each. Callers that already know the
    /// account uuid (it came from the config hint, or a sibling already settled it) use this and
    /// skip the network entirely; only a binding whose account is still unknown has to fall back
    /// to the fingerprint key, which is all it has before `/profile` answers.
    public func profile(accountUUID: String, fetchedAfter: Date) -> AccountIdentity? {
        guard let db else {
            let hit = memoryProfiles.values
                .filter { $0.identity.uuid == accountUUID && $0.fetchedAt >= fetchedAfter }
                .max { $0.fetchedAt < $1.fetchedAt }
            return hit?.identity
        }
        let sql = """
        SELECT account_uuid, email, display_name, organization_uuid, subscription_type, rate_limit_tier
        FROM account_profiles WHERE account_uuid=?1 AND fetched_at>=?2
        ORDER BY fetched_at DESC LIMIT 1
        """
        return readProfile(sql) { stmt in
            Self.bind(stmt, 1, text: accountUUID)
            Self.bind(stmt, 2, int: Self.millis(fetchedAfter))
        }
    }

    /// Remember a `/profile` answer so the fleet costs one lookup per token, not one per poll.
    public func setProfile(_ identity: AccountIdentity, tokenFingerprint: String, fetchedAt: Date) {
        guard let db else {
            memoryProfiles[tokenFingerprint] = (identity, fetchedAt)
            return
        }
        let sql = """
        INSERT OR REPLACE INTO account_profiles
        (token_fingerprint, account_uuid, email, display_name, organization_uuid,
         subscription_type, rate_limit_tier, fetched_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
        """
        guard let stmt = Self.prepare(db, sql) else { return }
        Self.bind(stmt, 1, text: tokenFingerprint)
        Self.bind(stmt, 2, text: identity.uuid)
        Self.bind(stmt, 3, text: identity.email)
        Self.bind(stmt, 4, text: identity.displayName)
        Self.bind(stmt, 5, text: identity.organizationUuid)
        Self.bind(stmt, 6, text: identity.subscriptionType)
        Self.bind(stmt, 7, text: identity.rateLimitTier)
        Self.bind(stmt, 8, int: Self.millis(fetchedAt))
        Self.step(stmt)
    }

    // MARK: - Retention

    /// Prune old rows: drop samples older than `retentionDays`, cap each account to its newest
    /// `maxRowsPerAccount`, and expire stale ledger rows. Runs incremental auto-vacuum to
    /// actually reclaim pages.
    ///
    /// The default cap is a generous safety net that sits **above** the 90-day window at the
    /// fastest cadence (adaptive 5-min running poll ≈ 288/day × 90 ≈ 26k), so retention is
    /// governed by age, not silently truncated by the cap.
    public func prune(now: Date, retentionDays: Int = 90, maxRowsPerAccount: Int = 50000) {
        guard let db else { return }
        let cutoff = Self.millis(now.addingTimeInterval(-Double(retentionDays) * 86400))

        if let stmt = Self.prepare(db, "DELETE FROM usage_samples WHERE captured_at < ?1") {
            Self.bind(stmt, 1, int: cutoff)
            Self.step(stmt)
        }
        // Keep only the newest `maxRowsPerAccount` per account. A single-pass ROW_NUMBER window
        // (linear) rather than a correlated COUNT (O(n²)); the `id` tiebreak keeps rows sharing
        // the newest millisecond from all escaping the cap.
        if let stmt = Self.prepare(db, """
        DELETE FROM usage_samples WHERE id IN (
            SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (
                    PARTITION BY account_uuid ORDER BY captured_at DESC, id DESC
                ) AS rn FROM usage_samples
            ) WHERE rn > ?1
        )
        """) {
            Self.bind(stmt, 1, int: Int64(maxRowsPerAccount))
            Self.step(stmt)
        }
        // Only expire dated ledger rows: a nil resets_at is stored as 0 (needed for dedup
        // matching), so `resets_at > 0` keeps no-reset entries from being wiped every prune and
        // re-notified.
        if let stmt = Self.prepare(
            db,
            "DELETE FROM notified_thresholds WHERE resets_at > 0 AND resets_at < ?1"
        ) {
            Self.bind(stmt, 1, int: cutoff)
            Self.step(stmt)
        }
        _ = Self.exec(db, "PRAGMA incremental_vacuum")
    }
}

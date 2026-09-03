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
    ///
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

    /// Run `body` with the open connection, on the actor's own executor; nil when the database
    /// could not be opened, which every caller degrades to an empty result.
    ///
    /// The handle stays **private**, and that is the point. Widening it to reach the timeline's
    /// read from another file also handed the whole module an `OpaquePointer` — which is
    /// `Sendable` — so anything could have awaited it and then used the connection off the
    /// actor, breaking the one-connection-per-thread rule that macOS `libsqlite3` imposes and
    /// that the comment beside it merely asserted. A closure cannot escape the isolation the way
    /// a returned pointer can.
    func withConnection<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard let db else { return nil }
        return body(db)
    }

    // MARK: - Samples

    /// Record a sample. `snapshot_json` is the canonical restore source; `raw_json` is kept for
    /// the inspector but **only on the latest sample per account** (older rows' raw is cleared to
    /// bound growth).
    public func record(_ sample: UsageSample, rawBody: Data?) {
        guard let db else { return }
        guard let snapshotJSON = Self.encodeSnapshot(sample.snapshot) else { return }

        // The insert + the raw-cleanup are one transaction so a crash can't leave raw cleared
        // with no new row.
        _ = Self.exec(db, "BEGIN")
        let sql = """
        INSERT INTO usage_samples
        (account_uuid, captured_at, snapshot_json, raw_json, source)
        VALUES (?1,?2,?3,?4,?5)
        """
        if let stmt = Self.prepare(db, sql) {
            Self.bind(stmt, 1, text: sample.accountUUID)
            Self.bind(stmt, 2, int: Self.millis(sample.capturedAt))
            Self.bind(stmt, 3, text: snapshotJSON)
            Self.bind(stmt, 4, text: rawBody.flatMap { String(data: $0, encoding: .utf8) })
            Self.bind(stmt, 5, text: sample.source)
            Self.step(stmt)
        }
        // Keep raw_json only on the account's newest row — computed *after* insert (against the
        // real max captured_at), so an out-of-order sample can't desync latest() from
        // latestRawJSON().
        if let stmt = Self.prepare(db, """
        UPDATE usage_samples SET raw_json=NULL
        WHERE account_uuid=?1 AND raw_json IS NOT NULL
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
        let resetsBucket = Self.resetBucketMillis(resetsAt)
        // Match `resets_at` within a full minute of the bucket rather than on exact equality, via a
        // `BETWEEN` range — index-friendly on the primary key's trailing `resets_at` (an `abs()`
        // predicate would force a scan). The tolerance folds two same-window cases exact equality
        // would miss onto one key: (1) a row written *before* this version, carrying the raw
        // un-bucketed millis, still matches its bucket on the first poll after upgrade instead of
        // re-firing once; (2) jitter around a boundary near :30s, which rounds two polls of one
        // window into *adjacent* minute buckets 60s apart. Distinct windows are ≥5h apart, far
        // outside ±60s, so the tolerance never merges two of them.
        //
        // A no-reset window (bucket 0) matches *exactly* on 0 — never a ±60s band around the epoch,
        // which would let the sentinel collide with a real window resetting within a minute of
        // 1970-01-01 (unreachable in practice, but the sentinel must carry no tolerance).
        let (low, high): (Int64, Int64) = resetsAt == nil ? (0, 0) : (
            resetsBucket - Self.resetBucketWidthMillis,
            resetsBucket + Self.resetBucketWidthMillis
        )
        guard let db else {
            // The degraded path carries the *same* tolerance as the SQL read below — dropping it
            // here would let a window straddling the :30 seam re-notify (and stack) whenever the
            // DB is unopenable, which is precisely the storm this ledger exists to stop. Memory
            // keys are always whole buckets, so walking them covers the `BETWEEN` range exactly.
            return stride(from: low, through: high, by: Int(Self.resetBucketWidthMillis)).contains {
                memoryNotified.contains(Self.notifiedKey(accountUUID, limitKey, threshold, $0))
            }
        }
        let sql = """
        SELECT 1 FROM notified_thresholds
        WHERE account_uuid=?1 AND limit_key=?2 AND threshold=?3
          AND resets_at BETWEEN ?4 AND ?5 LIMIT 1
        """
        guard let stmt = Self.prepare(db, sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        Self.bind(stmt, 2, text: limitKey)
        Self.bind(stmt, 3, double: threshold)
        Self.bind(stmt, 4, int: low)
        Self.bind(stmt, 5, int: high)
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
        let resetsBucket = Self.resetBucketMillis(resetsAt)
        guard let db else {
            memoryNotified.insert(Self.notifiedKey(accountUUID, limitKey, threshold, resetsBucket))
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
        Self.bind(stmt, 4, int: resetsBucket)
        Self.bind(stmt, 5, int: Self.millis(notifiedAt))
        Self.step(stmt)
    }

    /// Round the threshold so ledger writes and checks match on a stable value — the tiers are
    /// constants today, but this guards against a future computed threshold whose last float bit
    /// differs (a `REAL =` miss would re-notify).
    private static func roundedThreshold(_ threshold: Double) -> Double {
        (threshold * 1_000_000).rounded() / 1_000_000
    }

    /// Width of the dedup key's reset bucket (one minute, in millis) — also the tolerance
    /// `wasNotified` reads with, on both the SQLite and the in-memory path.
    private static let resetBucketWidthMillis: Int64 = 60000

    /// Bucket a window's reset instant to the nearest minute (in millis) for the dedup key — 0 for
    /// a no-reset window, matching how the ledger stores a nil `resetsAt`.
    ///
    /// The server reports `resets_at` as a *fixed* window boundary carrying sub-second jitter: a
    /// microsecond fractional part that differs on every response and wobbles across the whole-second
    /// edge (e.g. `13:59:59.857` then `14:00:00.357` for the same 14:00 boundary). Used raw as an
    /// equality key, that made each poll look like a new window and re-fired the same warning every
    /// tick. Rounding to the nearest minute collapses the jitter onto one key; two *genuinely*
    /// distinct windows are ≥5h apart (session) or ≥7d (weekly), so a one-minute bucket can never
    /// merge them. A boundary sitting near the :30s rounding seam can still split one window's
    /// jitter into adjacent buckets, which is why `wasNotified` matches within a full minute
    /// (±60000) rather than on exact bucket equality.
    public static func resetBucketMillis(_ resetsAt: Date?) -> Int64 {
        guard let resetsAt else { return 0 }
        let minute = resetBucketWidthMillis
        return (millis(resetsAt) + minute / 2) / minute * minute
    }

    private static func notifiedKey(
        _ uuid: String,
        _ limitKey: String,
        _ threshold: Double,
        _ resetsBucket: Int64
    ) -> String {
        "\(uuid)|\(limitKey)|\(threshold)|\(resetsBucket)"
    }

    // MARK: - Account profile (identity cache)

    /// The `/profile` answer for a token, if one was stored **and fetched no earlier than**
    /// `fetchedAfter`. Keyed by the token's fingerprint, so a re-login simply misses and
    /// re-fetches; the freshness bound then covers what can change without a new token — a
    /// renamed account, a changed email, a moved plan.
    public func profile(tokenFingerprint: String, fetchedAfter: Date) -> AccountIdentity? {
        // The DB path goes through `readProfile`, which re-checks the handle — so this only needs
        // to know whether to take the in-memory fallback, not bind the handle.
        guard db != nil else {
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

    /// The newest `/profile` answer stored for an **account**, whichever token carried it.
    ///
    /// The reverse of the lookup above, and the local account directory the config hint needs: a
    /// hint names a uuid and nothing else, so without this it could only ever be matched against
    /// accounts some *other* binding happened to resolve in the same pass. A user with one launcher
    /// per login — the common shape — never has such a sibling, which is exactly the case where a
    /// signed-out row has nothing to say about itself.
    ///
    /// **Newest wins, and that matters:** the table holds one row per token, so an account that has
    /// rotated its token several times has several rows here, and taking an arbitrary one would
    /// name a login from two rotations ago. Deliberately unbounded in age — unlike the fingerprint
    /// lookup, which takes a freshness cutoff — because this answers "what is this account called",
    /// not "is this reading current", and a name that is a month old still beats no name at all.
    ///
    /// No index for it: the table is bounded by the distinct tokens this machine has ever seen (a
    /// handful even after months), so a scan is free and adding one would cost a schema bump that
    /// drops every row — the opposite of what a directory is for.
    public func profile(accountUUID: String) -> AccountIdentity? {
        guard db != nil else {
            return memoryProfiles.values
                .filter { $0.identity.uuid == accountUUID }
                .max { $0.fetchedAt < $1.fetchedAt }?
                .identity
        }
        let sql = """
        SELECT account_uuid, email, display_name, organization_uuid, subscription_type, rate_limit_tier
        FROM account_profiles WHERE account_uuid=?1 ORDER BY fetched_at DESC LIMIT 1
        """
        return readProfile(sql) { stmt in
            Self.bind(stmt, 1, text: accountUUID)
        }
    }

    /// Run a prepared `account_profiles` SELECT (all lookups share the column list) and decode
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

    /// Move any state keyed on a token's *provisional* fingerprint uuid onto its now-authoritative
    /// account uuid, the first time `/profile` resolves it. Before the account is known, its
    /// throttle window, cached samples, and notification ledger are keyed on the fingerprint (the
    /// only id it has); when the uuid flips to the real account these would otherwise be orphaned —
    /// dropping a standing backoff, hiding last-known usage, and re-firing a notification. A no-op
    /// once identity is stable (nothing left under the fingerprint) or when the two already match.
    ///
    /// The usage throttle's `scope_key` *is* the account uuid (`usageScope(x) == x`); the identity
    /// scope (`identity:<fp>`) stays keyed by fingerprint and is deliberately not moved.
    public func reassignAccount(fromFingerprint fingerprint: String, toAccountUUID uuid: String) {
        guard fingerprint != uuid else { return }
        guard let db else {
            if let state = memoryThrottle.removeValue(forKey: fingerprint) {
                memoryThrottle[uuid] = state // best-effort; the ledger Set isn't re-keyed off-DB
            }
            return
        }
        for sql in [
            "UPDATE OR REPLACE throttle_state SET scope_key=?2 WHERE scope_key=?1",
            "UPDATE usage_samples SET account_uuid=?2 WHERE account_uuid=?1",
            "UPDATE OR REPLACE notified_thresholds SET account_uuid=?2 WHERE account_uuid=?1"
        ] {
            guard let stmt = Self.prepare(db, sql) else { continue }
            Self.bind(stmt, 1, text: fingerprint)
            Self.bind(stmt, 2, text: uuid)
            Self.step(stmt)
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

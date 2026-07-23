import Foundation
import SQLite3

/// SQLite's `SQLITE_TRANSIENT` — tells SQLite to copy a bound string, since our Swift buffer
/// doesn't outlive the call. (`SQLITE_STATIC` would be a use-after-free here.)
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
/// The SQLite primitives are `static` (nonisolated) helpers over an explicit handle, so the
/// synchronous `init` can open + bootstrap without touching actor-isolated methods; the actor
/// only serializes access to the `db` handle it holds.
public actor UsageHistoryStore {
    private let connection: SQLiteConnection
    private var db: OpaquePointer? {
        connection.handle
    }

    /// In-memory fallbacks used **only when the DB can't be opened**. History (samples) is
    /// genuinely optional and degrades to empty, but the throttle state and the notification
    /// ledger are not: losing the throttle would strip `UsageService`'s 60s floor and 429
    /// backoff and hammer the API, and losing the ledger would re-notify every tick. These keep
    /// both working for the session (just not persisted across restarts).
    private var memoryThrottle: [String: ThrottleState] = [:]
    private var memoryNotified: Set<String> = []

    /// Open (and bootstrap) the store at `path`. Pass `":memory:"` for a throwaway store in
    /// tests. A failed open leaves the store inert (every method no-ops / returns empty); the
    /// handle is closed by `SQLiteConnection.deinit` when the store is released.
    public init(path: String) {
        connection = SQLiteConnection(handle: Self.open(path: path))
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

    public func throttle(accountUUID: String) -> ThrottleState? {
        guard let db else { return memoryThrottle[accountUUID] }
        let sql = """
        SELECT last_attempt_at, backoff_until, backoff_reason, token_fingerprint
        FROM throttle_state WHERE account_uuid=?1
        """
        guard let stmt = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ThrottleState(
            lastAttemptAt: Self.optionalDate(stmt, 0),
            backoffUntil: Self.optionalDate(stmt, 1),
            backoffReason: Self.text(stmt, 2).flatMap(BackoffReason.init(rawValue:)),
            tokenFingerprint: Self.text(stmt, 3)
        )
    }

    public func setThrottle(_ state: ThrottleState, accountUUID: String) {
        guard let db else { memoryThrottle[accountUUID] = state; return }
        let sql = """
        INSERT INTO throttle_state (account_uuid, last_attempt_at, backoff_until, backoff_reason, token_fingerprint)
        VALUES (?1,?2,?3,?4,?5)
        ON CONFLICT(account_uuid) DO UPDATE SET
            last_attempt_at=excluded.last_attempt_at,
            backoff_until=excluded.backoff_until,
            backoff_reason=excluded.backoff_reason,
            token_fingerprint=excluded.token_fingerprint
        """
        guard let stmt = Self.prepare(db, sql) else { return }
        Self.bind(stmt, 1, text: accountUUID)
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

/// The nonisolated SQLite plumbing (open/bootstrap + statement primitives over an explicit
/// handle) lives in an extension so the actor body stays focused on the store's operations.
private extension UsageHistoryStore {
    // MARK: - Open + bootstrap (nonisolated; runs from init)

    private static func open(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        bootstrap(handle)
        return handle
    }

    private static func bootstrap(_ db: OpaquePointer) {
        _ = exec(db, "PRAGMA journal_mode=WAL")
        guard userVersion(db) != CoreConstants.usageSchemaVersion else { return }
        // A cache, not a contract: any version drift → drop & recreate.
        _ = exec(db, "DROP TABLE IF EXISTS usage_samples")
        _ = exec(db, "DROP TABLE IF EXISTS throttle_state")
        _ = exec(db, "DROP TABLE IF EXISTS notified_thresholds")
        _ = exec(db, "PRAGMA auto_vacuum=INCREMENTAL")
        _ = exec(db, "VACUUM")
        _ = exec(db, """
        CREATE TABLE usage_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_uuid TEXT NOT NULL,
            captured_at INTEGER NOT NULL,
            five_hour_frac REAL,
            seven_day_frac REAL,
            binding_frac REAL,
            extra_used_minor INTEGER,
            extra_limit_minor INTEGER,
            severity TEXT,
            snapshot_json TEXT NOT NULL,
            raw_json TEXT,
            source TEXT NOT NULL
        )
        """)
        _ = exec(db, "CREATE INDEX idx_samples_account_time ON usage_samples(account_uuid, captured_at)")
        _ = exec(db, """
        CREATE TABLE throttle_state (
            account_uuid TEXT PRIMARY KEY,
            last_attempt_at INTEGER,
            backoff_until INTEGER,
            backoff_reason TEXT,
            token_fingerprint TEXT
        )
        """)
        _ = exec(db, """
        CREATE TABLE notified_thresholds (
            account_uuid TEXT NOT NULL,
            limit_key TEXT NOT NULL,
            threshold REAL NOT NULL,
            resets_at INTEGER NOT NULL,
            notified_at INTEGER NOT NULL,
            PRIMARY KEY (account_uuid, limit_key, threshold, resets_at)
        )
        """)
        _ = exec(db, "PRAGMA user_version=\(CoreConstants.usageSchemaVersion)")
    }

    // MARK: - SQLite primitives (nonisolated statics over an explicit handle)

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func userVersion(_ db: OpaquePointer) -> Int {
        guard let stmt = prepare(db, "PRAGMA user_version") else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Prepare a statement. **The caller owns finalization** — statements stepped through the
    /// `step(_:)` helper are finalized there; those read with `sqlite3_step` directly finalize
    /// via a `defer`.
    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        return stmt
    }

    /// Step a write-only statement to completion and finalize it.
    private static func step(_ stmt: OpaquePointer) {
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private static func bind(_ stmt: OpaquePointer, _ index: Int32, text value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ index: Int32, int value: Int64?) {
        if let value {
            sqlite3_bind_int64(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ index: Int32, double value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, column)
        else {
            return nil
        }
        return String(cString: cString)
    }

    private static func optionalDate(_ stmt: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return date(fromMillis: sqlite3_column_int64(stmt, column))
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // MARK: - Snapshot JSON (canonical restore source)

    private static func encodeSnapshot(_ snapshot: UsageSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSnapshot(_ json: String) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    }
}

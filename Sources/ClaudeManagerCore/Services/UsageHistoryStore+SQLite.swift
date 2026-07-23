import Foundation
import SQLite3

/// SQLite's `SQLITE_TRANSIENT` — tells SQLite to copy a bound string, since our Swift buffer
/// doesn't outlive the call. (`SQLITE_STATIC` would be a use-after-free here.)
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The nonisolated SQLite plumbing (open/bootstrap + statement primitives over an explicit
/// handle) lives in an extension so the actor body stays focused on the store's operations.
extension UsageHistoryStore {
    // MARK: - Open + bootstrap (nonisolated; runs from init)

    static func open(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        bootstrap(handle)
        return handle
    }

    static func bootstrap(_ db: OpaquePointer) {
        _ = exec(db, "PRAGMA journal_mode=WAL")
        guard userVersion(db) != CoreConstants.usageSchemaVersion else { return }
        // A cache, not a contract: any version drift → drop & recreate.
        _ = exec(db, "DROP TABLE IF EXISTS usage_samples")
        _ = exec(db, "DROP TABLE IF EXISTS throttle_state")
        _ = exec(db, "DROP TABLE IF EXISTS notified_thresholds")
        _ = exec(db, "DROP TABLE IF EXISTS account_profiles")
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
        // Keyed by token fingerprint, not account uuid: the profile is a property of the token,
        // so a re-login (new token → new fingerprint) misses the cache and re-fetches on its own,
        // with no staleness rule to maintain. It also lets a binding that has no account-UUID
        // hint reuse its lookup, where the uuid isn't known until `/profile` answers.
        _ = exec(db, """
        CREATE TABLE account_profiles (
            token_fingerprint TEXT PRIMARY KEY,
            account_uuid TEXT NOT NULL,
            email TEXT,
            display_name TEXT,
            organization_uuid TEXT,
            subscription_type TEXT,
            rate_limit_tier TEXT,
            fetched_at INTEGER NOT NULL
        )
        """)
        _ = exec(db, "PRAGMA user_version=\(CoreConstants.usageSchemaVersion)")
    }

    // MARK: - SQLite primitives (nonisolated statics over an explicit handle)

    static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    static func userVersion(_ db: OpaquePointer) -> Int {
        guard let stmt = prepare(db, "PRAGMA user_version") else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Prepare a statement. **The caller owns finalization** — statements stepped through the
    /// `step(_:)` helper are finalized there; those read with `sqlite3_step` directly finalize
    /// via a `defer`.
    static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        return stmt
    }

    /// Step a write-only statement to completion and finalize it.
    static func step(_ stmt: OpaquePointer) {
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    static func bind(_ stmt: OpaquePointer, _ index: Int32, text value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bind(_ stmt: OpaquePointer, _ index: Int32, int value: Int64?) {
        if let value {
            sqlite3_bind_int64(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bind(_ stmt: OpaquePointer, _ index: Int32, double value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, column)
        else {
            return nil
        }
        return String(cString: cString)
    }

    static func optionalDate(_ stmt: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return date(fromMillis: sqlite3_column_int64(stmt, column))
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // MARK: - Snapshot JSON (canonical restore source)

    static func encodeSnapshot(_ snapshot: UsageSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeSnapshot(_ json: String) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    }
}

import Foundation
import SQLite3

/// One thinned observation for the timeline: when it was taken, and where each window stood.
///
/// Every utilization is optional because a snapshot need not carry every window — a plan with no
/// per-model weekly limit reports none, and an older server sent no `limits[]` at all. A missing
/// value is a gap in the line, never a zero: drawing an unreported window as 0% would show a
/// quota being spent down to nothing.
public struct UsageSeriesPoint: Sendable, Equatable {
    /// The moment the sample this point came from was captured — the real timestamp, not the
    /// bucket boundary it was grouped into.
    public var at: Date
    public var session: Double?
    public var weeklyAll: Double?
    /// The highest scoped weekly window in that snapshot. Highest, because with more than one
    /// per-model window the line is meant to show the pressure that constrains, and a mean over
    /// two models describes neither of them.
    public var weeklyScoped: Double?

    public init(at: Date, session: Double?, weeklyAll: Double?, weeklyScoped: Double?) {
        self.at = at
        self.session = session
        self.weeklyAll = weeklyAll
        self.weeklyScoped = weeklyScoped
    }
}

public extension UsageHistoryStore {
    /// The account's usage over time, thinned to at most one point per `step`.
    ///
    /// **Thinned by taking the last sample in each bucket, never a mean.** A weekly window resets
    /// to zero inside some bucket, and averaging across that boundary invents a mid-way value
    /// that the account never held — smearing the very event the timeline exists to show. The
    /// last sample in a bucket reports the window as it actually stood at the end of it, reset
    /// included.
    ///
    /// The thinning is the point of doing it in SQL. A month of polling is thousands of rows per
    /// account, and while the index still bounds the scan, exactly one `snapshot_json` per bucket
    /// crosses into Swift to be decoded — which is the cost that actually matters here.
    ///
    /// Degrades to empty like every other read on this store: an unopenable database, a `step`
    /// that is not a usable positive number, or an account with nothing recorded all return no
    /// points rather than failing the caller.
    func series(accountUUID: String, since: Date, step: TimeInterval) -> [UsageSeriesPoint] {
        guard let db, step > 0 else { return [] }
        // `Int64(_:)` **traps** on a value it cannot represent, and `step > 0` lets `.infinity`
        // and anything past `Int64.max / 1000` through — so the obvious conversion takes the
        // process down on a caller's arithmetic slip, in a read whose whole contract is to
        // degrade to empty. (`NaN` is already excluded: every comparison against it is false.)
        let millis = step * 1000
        guard millis < Double(Int64.max) else { return [] }
        let bucket = Int64(millis)
        guard bucket > 0 else { return [] }
        // One row per bucket, ranked rather than aggregated. `MAX(captured_at)` with a bare
        // `snapshot_json` beside it reads well — SQLite documents that the bare columns come
        // from the row achieving the maximum — but it settles nothing when two samples share a
        // millisecond, which the schema permits: both rows achieve the maximum and either
        // snapshot may come back. `ROW_NUMBER` lets the tie be broken by `id`, so the point is
        // the last sample of its bucket by the clock and, failing that, by insertion.
        let sql = """
        SELECT captured_at, snapshot_json FROM (
            SELECT captured_at, snapshot_json,
                   ROW_NUMBER() OVER (
                       PARTITION BY captured_at/?3 ORDER BY captured_at DESC, id DESC
                   ) AS rank
            FROM usage_samples
            WHERE account_uuid=?1 AND captured_at>=?2
        ) WHERE rank=1
        ORDER BY captured_at
        """
        guard let stmt = Self.prepare(db, sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, text: accountUUID)
        Self.bind(stmt, 2, int: Self.millis(since))
        Self.bind(stmt, 3, int: bucket)
        var points: [UsageSeriesPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let json = Self.text(stmt, 1), let snapshot = Self.decodeSnapshot(json) else {
                continue
            }
            points.append(
                UsageSeriesPoint(
                    at: Self.date(fromMillis: sqlite3_column_int64(stmt, 0)),
                    session: snapshot.session?.utilization,
                    weeklyAll: snapshot.weeklyAll?.utilization,
                    weeklyScoped: snapshot.weeklyScoped.map(\.utilization).max()
                )
            )
        }
        return points
    }
}

import Foundation
import Testing
@testable import ClaudeManagerCore

struct UsageHistoryStoreTests {
    private func makeSnapshot(
        sevenDay: Double,
        extraUsed: Int? = nil,
        extraLimit: Int? = nil
    ) -> UsageSnapshot {
        var limits = [UsageLimit(rawKind: UsageLimit.kindWeeklyAll, utilization: sevenDay, isActive: true)]
        limits.append(UsageLimit(rawKind: UsageLimit.kindSession, utilization: 0.1, isActive: true))
        let extra = extraUsed.map {
            ExtraUsage(
                isEnabled: true,
                usedMinor: $0,
                limitMinor: extraLimit,
                utilization: nil,
                currency: "USD"
            )
        }
        return UsageSnapshot(limits: limits, extra: extra)
    }

    private func sample(_ account: String, at seconds: Double, sevenDay: Double = 0.5) -> UsageSample {
        UsageSample(
            accountUUID: account,
            capturedAt: Date(timeIntervalSince1970: seconds),
            snapshot: makeSnapshot(sevenDay: sevenDay),
            source: "desktop:\(account)"
        )
    }

    private func withStore(_ body: (UsageHistoryStore) async -> Void) async {
        let store = UsageHistoryStore(path: ":memory:")
        await body(store)
    }

    // MARK: - Round-trip

    @Test
    func recordsAndReturnsLatestSnapshot() async {
        await withStore { store in
            await store.record(sample("acc", at: 100, sevenDay: 0.4), rawBody: nil)
            await store.record(sample("acc", at: 200, sevenDay: 0.7), rawBody: nil)
            let latest = await store.latest(accountUUID: "acc")
            #expect(latest?.capturedAt == Date(timeIntervalSince1970: 200))
            #expect(latest?.snapshot.weeklyAll?.utilization == 0.7)
            #expect(latest?.source == "desktop:acc")
            #expect(await store.sampleCount(accountUUID: "acc") == 2)
        }
    }

    @Test
    func latestIsPerAccount() async {
        await withStore { store in
            await store.record(sample("a", at: 100), rawBody: nil)
            await store.record(sample("b", at: 200), rawBody: nil)
            #expect(await store.latest(accountUUID: "a")?.capturedAt == Date(timeIntervalSince1970: 100))
            #expect(await store.latest(accountUUID: "b")?.capturedAt == Date(timeIntervalSince1970: 200))
            #expect(await store.latest(accountUUID: "missing") == nil)
        }
    }

    // MARK: - raw_json is latest-only

    @Test
    func rawJSONKeptOnlyForLatestSample() async {
        await withStore { store in
            await store.record(sample("acc", at: 100), rawBody: Data(#"{"first":1}"#.utf8))
            #expect(await store.latestRawJSON(accountUUID: "acc") == #"{"first":1}"#)
            // A newer sample clears the older row's raw.
            await store.record(sample("acc", at: 200), rawBody: Data(#"{"second":2}"#.utf8))
            #expect(await store.latestRawJSON(accountUUID: "acc") == #"{"second":2}"#)
            // Still two samples, but only one carries raw_json.
            #expect(await store.sampleCount(accountUUID: "acc") == 2)
        }
    }

    // MARK: - Throttle state

    @Test
    func throttleStateRoundTrips() async {
        await withStore { store in
            #expect(await store.throttle(accountUUID: "acc") == nil)
            let state = ThrottleState(
                lastAttemptAt: Date(timeIntervalSince1970: 1000),
                backoffUntil: Date(timeIntervalSince1970: 1300),
                tokenFingerprint: "abc123"
            )
            await store.setThrottle(state, accountUUID: "acc")
            #expect(await store.throttle(accountUUID: "acc") == state)
            // Upsert overwrites.
            let updated = ThrottleState(
                lastAttemptAt: Date(timeIntervalSince1970: 2000),
                tokenFingerprint: "def456"
            )
            await store.setThrottle(updated, accountUUID: "acc")
            #expect(await store.throttle(accountUUID: "acc") == updated)
        }
    }

    // MARK: - Notification ledger

    @Test
    func notificationLedgerDedups() async {
        await withStore { store in
            let reset = Date(timeIntervalSince1970: 9999)
            #expect(await store.wasNotified(
                accountUUID: "acc",
                limitKey: "7d",
                threshold: 0.9,
                resetsAt: reset
            ) == false)
            await store.markNotified(
                accountUUID: "acc",
                limitKey: "7d",
                threshold: 0.9,
                resetsAt: reset,
                notifiedAt: Date(timeIntervalSince1970: 5000)
            )
            #expect(await store.wasNotified(
                accountUUID: "acc",
                limitKey: "7d",
                threshold: 0.9,
                resetsAt: reset
            ) == true)
            // A different reset window is a fresh notification.
            let nextReset = Date(timeIntervalSince1970: 20000)
            #expect(await store.wasNotified(
                accountUUID: "acc",
                limitKey: "7d",
                threshold: 0.9,
                resetsAt: nextReset
            ) == false)
        }
    }

    // MARK: - Retention

    @Test
    func prunesSamplesOlderThanRetentionWindow() async {
        await withStore { store in
            let now = Date(timeIntervalSince1970: 100 * 86400)
            await store.record(sample("acc", at: 1 * 86400), rawBody: nil) // 99 days old
            await store.record(sample("acc", at: 95 * 86400), rawBody: nil) // 5 days old
            await store.prune(now: now, retentionDays: 90)
            #expect(await store.sampleCount(accountUUID: "acc") == 1)
            #expect(await store.latest(accountUUID: "acc")?
                .capturedAt == Date(timeIntervalSince1970: 95 * 86400))
        }
    }

    @Test
    func prunesToRowCapPerAccount() async {
        await withStore { store in
            for i in 1 ... 6 {
                await store.record(sample("acc", at: Double(i)), rawBody: nil)
            }
            await store.prune(now: Date(timeIntervalSince1970: 1000), retentionDays: 90, maxRowsPerAccount: 3)
            #expect(await store.sampleCount(accountUUID: "acc") == 3)
            // The newest survive.
            #expect(await store.latest(accountUUID: "acc")?.capturedAt == Date(timeIntervalSince1970: 6))
        }
    }

    // MARK: - Degrade-not-crash

    @Test
    func unopenableStoreDegradesToEmpty() async {
        // A path under a nonexistent directory can't be created → inert store, no crash.
        let store = UsageHistoryStore(path: "/nonexistent-dir-xyz/usage.db")
        await store.record(sample("acc", at: 100), rawBody: nil)
        #expect(await store.latest(accountUUID: "acc") == nil)
        #expect(await store.sampleCount(accountUUID: "acc") == 0)
        #expect(await store.throttle(accountUUID: "acc") == nil)
    }
}

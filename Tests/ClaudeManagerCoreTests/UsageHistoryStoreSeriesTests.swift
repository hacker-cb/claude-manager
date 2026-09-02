import Foundation
import Testing
@testable import ClaudeManagerCore

/// The timeline's read: how the history is thinned, and what a thinned point may claim.
struct UsageHistoryStoreSeriesTests {
    private static let hour: TimeInterval = 3600

    private func snapshot(
        session: Double? = nil,
        weeklyAll: Double? = nil,
        scoped: [Double] = []
    ) -> UsageSnapshot {
        var limits: [UsageLimit] = []
        if let session {
            limits.append(UsageLimit(rawKind: UsageLimit.kindSession, utilization: session))
        }
        if let weeklyAll {
            limits.append(UsageLimit(rawKind: UsageLimit.kindWeeklyAll, utilization: weeklyAll))
        }
        for (index, value) in scoped.enumerated() {
            limits.append(UsageLimit(
                rawKind: UsageLimit.kindWeeklyScoped,
                utilization: value,
                scopeModelName: "Model\(index)"
            ))
        }
        return UsageSnapshot(limits: limits)
    }

    private func sample(
        _ account: String,
        at seconds: Double,
        session: Double? = nil,
        weeklyAll: Double? = nil,
        scoped: [Double] = []
    ) -> UsageSample {
        UsageSample(
            accountUUID: account,
            capturedAt: Date(timeIntervalSince1970: seconds),
            snapshot: snapshot(session: session, weeklyAll: weeklyAll, scoped: scoped),
            source: "desktop:\(account)"
        )
    }

    private func withStore(_ body: (UsageHistoryStore) async -> Void) async {
        await body(UsageHistoryStore(path: ":memory:"))
    }

    private func series(
        _ store: UsageHistoryStore,
        _ account: String = "acc",
        since: Double = 0,
        step: TimeInterval = hour
    ) async -> [UsageSeriesPoint] {
        await store.series(
            accountUUID: account,
            since: Date(timeIntervalSince1970: since),
            step: step
        )
    }

    // MARK: - Thinning

    @Test
    func manySamplesInOneBucketCollapseToTheLastOne() async {
        await withStore { store in
            for (offset, value) in [0.1, 0.2, 0.3, 0.4].enumerated() {
                await store.record(
                    sample("acc", at: Double(offset) * 600, weeklyAll: value),
                    rawBody: nil
                )
            }
            let points = await series(store)
            #expect(points.count == 1)
            // The last sample of the bucket, not a mean of the four.
            #expect(points.first?.weeklyAll == 0.4)
            #expect(points.first?.at == Date(timeIntervalSince1970: 1800))
        }
    }

    @Test
    func aResetInsideABucketIsShownAsAReset() async {
        // The reason the thinning takes the last sample rather than averaging: a mean across a
        // reset boundary reports a value the account never held, and smears the one event the
        // timeline exists to show.
        await withStore { store in
            await store.record(sample("acc", at: 600, weeklyAll: 0.9), rawBody: nil)
            await store.record(sample("acc", at: 1200, weeklyAll: 0.02), rawBody: nil)
            #expect(await series(store).first?.weeklyAll == 0.02)
        }
    }

    @Test
    func bucketsComeBackInOrderOneToAPeriod() async {
        await withStore { store in
            for bucket in 0 ..< 4 {
                await store.record(
                    sample("acc", at: Double(bucket) * Self.hour + 60, weeklyAll: 0.1 * Double(bucket)),
                    rawBody: nil
                )
                await store.record(
                    sample("acc", at: Double(bucket) * Self.hour + 120, weeklyAll: 0.5),
                    rawBody: nil
                )
            }
            let points = await series(store)
            #expect(points.count == 4)
            #expect(points.map(\.at) == (0 ..< 4).map {
                Date(timeIntervalSince1970: Double($0) * Self.hour + 120)
            })
            #expect(points.allSatisfy { $0.weeklyAll == 0.5 })
        }
    }

    @Test
    func aCoarserStepFoldsMoreBucketsTogether() async {
        await withStore { store in
            for bucket in 0 ..< 6 {
                await store.record(
                    sample("acc", at: Double(bucket) * Self.hour, weeklyAll: 0.3),
                    rawBody: nil
                )
            }
            #expect(await series(store, step: Self.hour).count == 6)
            #expect(await series(store, step: Self.hour * 3).count == 2)
        }
    }

    // MARK: - Bounds

    @Test
    func samplesBeforeTheStartAreNotRead() async {
        await withStore { store in
            await store.record(sample("acc", at: 100, weeklyAll: 0.1), rawBody: nil)
            await store.record(sample("acc", at: 10000, weeklyAll: 0.6), rawBody: nil)
            let points = await series(store, since: 5000)
            #expect(points.count == 1)
            #expect(points.first?.weeklyAll == 0.6)
        }
    }

    @Test
    func theSeriesIsPerAccount() async {
        await withStore { store in
            await store.record(sample("a", at: 100, weeklyAll: 0.1), rawBody: nil)
            await store.record(sample("b", at: 100, weeklyAll: 0.9), rawBody: nil)
            #expect(await series(store, "a").first?.weeklyAll == 0.1)
            #expect(await series(store, "b").first?.weeklyAll == 0.9)
            #expect(await series(store, "nobody").isEmpty)
        }
    }

    // MARK: - What a point carries

    @Test
    func everyWindowIsCarriedAndTheScopedOneIsTheHighest() async {
        await withStore { store in
            await store.record(
                sample("acc", at: 100, session: 0.2, weeklyAll: 0.4, scoped: [0.3, 0.7]),
                rawBody: nil
            )
            let point = await series(store).first
            #expect(point?.session == 0.2)
            #expect(point?.weeklyAll == 0.4)
            // Highest, not a mean: the line is meant to show the pressure that constrains.
            #expect(point?.weeklyScoped == 0.7)
        }
    }

    @Test
    func anUnreportedWindowIsAGapNotAZero() async {
        // Drawing a window nobody reported as 0% would show a quota being spent down to nothing.
        await withStore { store in
            await store.record(sample("acc", at: 100, weeklyAll: 0.4), rawBody: nil)
            let point = await series(store).first
            #expect(point?.weeklyAll == 0.4)
            #expect(point?.session == nil)
            #expect(point?.weeklyScoped == nil)
        }
    }

    // MARK: - Degrade, never fail

    @Test
    func anEmptyStoreReturnsNoPoints() async {
        await withStore { store in
            #expect(await series(store).isEmpty)
        }
    }

    @Test
    func aNonPositiveStepReturnsNoPoints() async {
        await withStore { store in
            await store.record(sample("acc", at: 100, weeklyAll: 0.4), rawBody: nil)
            #expect(await series(store, step: 0).isEmpty)
            #expect(await series(store, step: -3600).isEmpty)
        }
    }

    @Test
    func anUnopenableDatabaseReturnsNoPointsRatherThanFailing() async {
        let store = UsageHistoryStore(path: "/nonexistent-directory/usage.db")
        let points = await store.series(
            accountUUID: "acc",
            since: Date(timeIntervalSince1970: 0),
            step: Self.hour
        )
        #expect(points.isEmpty)
    }
}

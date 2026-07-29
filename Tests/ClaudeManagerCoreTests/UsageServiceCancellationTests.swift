import Foundation
import Testing
@testable import ClaudeManagerCore

/// The master switch, as the code actually implements it: five `Task.isCancelled` checks spread
/// across `UsageService.refresh` and `AccountResolver.resolve`, none of which had a test.
///
/// README and SECURITY.md both promise that turning tracking off stops the work that has not
/// happened *yet* — no further keychain read, no further call, nothing written. Every guard below
/// is load-bearing for that sentence, and until now every one of them was a line anybody could
/// delete without a single test going red.
///
/// Their own file rather than more weight on `UsageServiceTests`, whose body is already close to
/// the `type_body_length` limit; an extension keeps the shared harness reachable.
extension UsageServiceTests {
    @Test
    func cancellingWhileTokensAreReadCallsNothingAtAll() async {
        // The switch flips during the keychain pass. Resolving already-past a check still finishes
        // reading the binding in hand, but the pass must then fetch nothing — which is what makes
        // "off stops all polling" true of the work that hadn't happened when the user said stop.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: CancellingProvider(cancelOn: "p1", results: [
                "p1": .success(token("p1")),
                "p2": .success(token("p2", value: "TK-2"))
            ]),
            http: http,
            history: history
        )

        // A child task, so the cancellation lands on the pass rather than on the test's own task.
        let task = Task { await service.refresh(bindings: [binding("p1"), binding("p2")], now: now) }
        let result = await task.value

        #expect(http.callCount == 0) // neither /profile nor /usage
        #expect(result.accounts.isEmpty)
    }

    @Test
    func cancellingInsideTheUsageFetchWritesNeitherSampleNorThrottle() async {
        // A cancelled `URLSession` call surfaces as a perfectly ordinary response here, so the
        // check after the fetch is the only thing standing between "off" and a sample landing in
        // usage.db afterwards. An offline-backoff row written here would be worse still: it would
        // serve the account stale on re-enable.
        let body = usageBody
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            withUnsafeCurrentTask { $0?.cancel() }
            return HTTPResponse(status: 200, body: body)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )

        let task = Task { await service.refresh(bindings: [binding("p")], now: now) }
        _ = await task.value

        #expect(http.usageCallCount == 1)
        #expect(await history.sampleCount(accountUUID: "acct") == 0)
        #expect(await history.throttle(scope: UsageService.usageScope("acct")) == nil)
    }

    @Test
    func cancellingBetweenAccountsLeavesTheRestOfTheFleetUnfetched() async {
        // Two logins, one pass. Without the between-accounts check, turning tracking off part-way
        // through a fleet still issued every remaining call and still wrote every remaining row.
        let body = usageBody
        let http = ScriptedHTTP { url, index in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct-\(index)"))
            }
            withUnsafeCurrentTask { $0?.cancel() }
            return HTTPResponse(status: 200, body: body)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: [
                "p1": .success(token("p1")),
                "p2": .success(token("p2", value: "TK-2"))
            ]),
            http: http,
            history: history
        )

        let task = Task { await service.refresh(bindings: [binding("p1"), binding("p2")], now: now) }
        let result = await task.value

        // Both identities settled before any usage was fetched — that pass runs first and had not
        // been cancelled yet — and then exactly one account was attempted.
        #expect(http.profileCallCount == 2)
        #expect(http.usageCallCount == 1)
        #expect(result.accounts.count == 1)
    }
}

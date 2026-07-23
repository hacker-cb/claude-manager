import Foundation
import Testing
@testable import ClaudeManagerCore

struct UsageServiceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private let usageBody = Data(#"{"limits":[{"kind":"weekly_all","percent":50,"is_active":true}]}"#.utf8)

    // MARK: - Poll cadence

    @Test
    func pollIntervalHonorsBaseAndAdaptiveLane() {
        // Base interval in seconds; a sub-minute / manual (0) value floors to one minute.
        #expect(UsageService
            .pollIntervalSeconds(minutes: 30, adaptiveEnabled: false, anyRunning: false) == 1800)
        #expect(UsageService.pollIntervalSeconds(minutes: 0, adaptiveEnabled: false, anyRunning: false) == 60)
        // Adaptive drops to the 5-min lane only while an account is running…
        #expect(UsageService.pollIntervalSeconds(minutes: 30, adaptiveEnabled: true, anyRunning: true) == 300)
        #expect(UsageService
            .pollIntervalSeconds(minutes: 30, adaptiveEnabled: true, anyRunning: false) == 1800)
        // …and never makes an already-shorter interval slower.
        #expect(UsageService.pollIntervalSeconds(minutes: 2, adaptiveEnabled: true, anyRunning: true) == 120)
    }

    // MARK: - Fetch + persist

    @Test
    func freshFetchRecordsAndReturnsFresh() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.state == .fresh)
        #expect(result.accounts.first?.snapshot?.weeklyAll?.utilization == 0.5)
        #expect(http.usageCallCount == 1)
        #expect(await history.sampleCount(accountUUID: "acct") == 1)
    }

    @Test
    func dedupIssuesOneRequestForSharedAccount() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1", lastKnown: "acct")),
            "p2": .success(token("p2", lastKnown: "acct"))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("p1"), binding("p2")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["p1", "p2"])
        #expect(http.usageCallCount == 1)
    }

    @Test
    func bindingFailuresAreReported() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "ok": .success(token("ok", lastKnown: "acct")),
            "locked": .failure(.keychainUnavailable(.interactionNotAllowed))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("ok"), binding("locked")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.bindingFailures["locked"] == .keychainUnavailable(.interactionNotAllowed))
    }

    // MARK: - Identity reconciliation

    @Test
    func provisionalIdentityIsReconciledViaProfile() async {
        // No `lastKnownAccountUuid` hint → the resolver keys by binding id and flags the identity
        // provisional; the service must settle it via `/profile` before storing anything.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct-real")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.identity.uuid == "acct-real")
        #expect(result.accounts.first?.identity.email == "user@example.com")
        #expect(result.accounts.first?.state == .fresh)
        #expect(http.profileCallCount == 1)
        #expect(http.usageCallCount == 1)
        // Persisted under the authoritative uuid — not the binding id it started with.
        #expect(await history.sampleCount(accountUUID: "acct-real") == 1)
        #expect(await history.sampleCount(accountUUID: "p") == 0)
    }

    @Test
    func profileFailureKeepsProvisionalIdentity() async {
        // `/profile` unreachable → keep the provisional key rather than dropping the account;
        // usage still works, just keyed per binding until a later poll settles it.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 500, body: Data())
            }
            return HTTPResponse(status: 200, body: usageBody)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.identity.uuid == "p")
        #expect(result.accounts.first?.state == .fresh)
        #expect(await history.sampleCount(accountUUID: "p") == 1)
    }

    @Test
    func storedProfileIsReusedInsteadOfRefetched() async {
        // The name is cached per token, so a second pass costs no extra /profile call — and a
        // hinted account keeps its own uuid, taking only the naming fields from /profile.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "ignored-for-hinted")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        // Past the 60s floor so the second pass genuinely fetches usage again.
        let later = now.addingTimeInterval(120)
        let result = await service.refresh(bindings: [binding("p")], now: later)
        #expect(result.accounts.first?.identity.uuid == "acct")
        #expect(result.accounts.first?.identity.email == "user@example.com")
        #expect(http.usageCallCount == 2)
        #expect(http.profileCallCount == 1) // fetched once, reused after
    }

    @Test
    func staleProfileIsRefetchedAfterTTL() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        let afterTTL = now.addingTimeInterval(UsageService.profileTTLSeconds + 60)
        _ = await service.refresh(bindings: [binding("p")], now: afterTTL)
        #expect(http.profileCallCount == 2) // the day-old answer is re-asked, not trusted
    }

    // MARK: - Throttle / expiry

    @Test
    func expiredTokenSkipsFetchLoginNeeded() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let expired = token("p", expiresAt: Date(timeIntervalSince1970: 1), lastKnown: "acct")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(expired)]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.state == .loginNeeded)
        #expect(http.usageCallCount == 0)
    }

    @Test
    func floorSkipsRefetchWithinWindow() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        let second = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(30)) // < 60s
        #expect(http.usageCallCount == 1)
        if case .stale = second.accounts.first?.state {} else {
            Issue.record("expected stale, got \(String(describing: second.accounts.first?.state))")
        }
    }

    @Test
    func rateLimitedBacksOffAndSkipsWithinWindow() async {
        let http = ScriptedHTTP { _, _ in
            HTTPResponse(status: 429, body: Data(), headers: ["retry-after": "120"])
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        let first = await service.refresh(bindings: [binding("p")], now: now)
        #expect(first.accounts.first?.state == .rateLimited(until: now.addingTimeInterval(120)))
        // 60s later, still inside the 120s backoff → no new request.
        let second = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(60))
        #expect(http.usageCallCount == 1)
        #expect(second.accounts.first?.state == .rateLimited(until: now.addingTimeInterval(120)))
    }

    @Test
    func unauthorizedIsTerminalUntilTokenChanges() async {
        let history = UsageHistoryStore(path: ":memory:")
        let http401 = ScriptedHTTP { _, _ in HTTPResponse(status: 401, body: Data()) }
        let serviceA = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http401,
            history: history
        )
        let first = await serviceA.refresh(bindings: [binding("p")], now: now)
        #expect(first.accounts.first?.state == .loginNeeded)
        #expect(http401.usageCallCount == 1)
        // Same token much later → still parked, no new call.
        _ = await serviceA.refresh(bindings: [binding("p")], now: now.addingTimeInterval(100_000))
        #expect(http401.usageCallCount == 1)
        // A different token value (fingerprint change = re-login) → retries.
        let httpOK = ScriptedHTTP(usage: usageBody)
        let serviceB = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "NEW", lastKnown: "acct"))]),
            http: httpOK,
            history: history
        )
        let retried = await serviceB.refresh(bindings: [binding("p")], now: now.addingTimeInterval(200_000))
        #expect(httpOK.usageCallCount == 1)
        #expect(retried.accounts.first?.state == .fresh)
    }

    @Test
    func transportFailureIsOffline() async {
        let http = ScriptedHTTP { _, _ in throw URLError(.notConnectedToInternet) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.state == .offline)
    }

    @Test
    func transportBackoffDoesNotReadBackAsRateLimited() async {
        let history = UsageHistoryStore(path: ":memory:")
        // Seed a good sample so the later stale read has data.
        let ok = ScriptedHTTP(usage: usageBody)
        _ = await makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: ok, history: history
        ).refresh(bindings: [binding("p")], now: now)
        // Transport failure > 60s later → offline backoff (with reason .offline).
        let down = ScriptedHTTP { _, _ in throw URLError(.notConnectedToInternet) }
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: down, history: history
        )
        let failed = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(120))
        #expect(failed.accounts.first?.state == .offline)
        // Next tick, still inside the backoff, must render stale — not a phantom 429.
        let next = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(180))
        if case .stale = next.accounts.first?.state {} else {
            Issue.record("expected stale, got \(String(describing: next.accounts.first?.state))")
        }
    }

    // MARK: - Fleet-level key self-heal

    /// Fails every binding with `.decryptFailed` on the first resolve pass (a stale shared key),
    /// then succeeds — modelling exactly the fleet self-heal path (fail-all → invalidate → retry)
    /// deterministically, without depending on which garbage a wrong AES key happens to produce.
    private final class TwoPassProvider: TokenProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let firstPassCount: Int
        private let healed: DesktopToken
        init(firstPassCount: Int, healed: DesktopToken) {
            self.firstPassCount = firstPassCount
            self.healed = healed
        }

        func token(
            for _: TokenBinding,
            interactive _: Bool
        ) async -> Result<DesktopToken, TokenProviderError> {
            let n = lock.withLock { calls += 1; return calls }
            return n <= firstPassCount ? .failure(.decryptFailed(.decryptFailed)) : .success(healed)
        }
    }

    @Test
    func fleetSelfHealRetriesWhenAllDecryptsFail() async {
        let history = UsageHistoryStore(path: ":memory:")
        let http = ScriptedHTTP(usage: usageBody)
        // One binding: pass 1 → .decryptFailed (all fail) → self-heal invalidates + retries →
        // pass 2 → success. If self-heal didn't run, the account would never resolve.
        let provider = TwoPassProvider(firstPassCount: 1, healed: token("p", lastKnown: "acct"))
        let service = UsageService(
            resolver: AccountResolver(provider: provider),
            client: AnthropicOAuthClient(http: http),
            keyStore: SafeStorageKeyStore(keychain: StubKeychainAlways(Data("pw".utf8))),
            history: history,
            marketingVersion: "1.0"
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.state == .fresh)
    }

    @Test
    func doesNotSelfHealOnMalformedCacheOnly() async {
        let history = UsageHistoryStore(path: ":memory:")
        let http = ScriptedHTTP(usage: usageBody)
        // All bindings decrypt fine but the payload is malformed (key is correct) → no self-heal,
        // no retry: the failure is reported, not masked as a rotated key.
        let provider = StubProvider(results: ["p": .failure(.malformedCache)])
        let service = UsageService(
            resolver: AccountResolver(provider: provider),
            client: AnthropicOAuthClient(http: http),
            keyStore: SafeStorageKeyStore(keychain: StubKeychainAlways(Data("pw".utf8))),
            history: history,
            marketingVersion: "1.0"
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.isEmpty)
        #expect(result.bindingFailures["p"] == .malformedCache)
    }
}

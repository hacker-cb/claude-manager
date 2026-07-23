import Foundation
import Testing
@testable import ClaudeManagerCore

struct UsageServiceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private let usageBody = Data(#"{"limits":[{"kind":"weekly_all","percent":50,"is_active":true}]}"#.utf8)

    // MARK: - Harness

    private struct StubProvider: TokenProvider {
        let results: [String: Result<DesktopToken, TokenProviderError>]
        func token(
            for binding: TokenBinding,
            interactive _: Bool
        ) async -> Result<DesktopToken, TokenProviderError> {
            results[binding.id] ?? .failure(.configUnreadable)
        }
    }

    /// Records call count; each call runs `handler(callIndex)` (1-based) → response or throw.
    private final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let handler: @Sendable (Int) throws -> HTTPResponse
        init(_ handler: @escaping @Sendable (Int) throws -> HTTPResponse) {
            self.handler = handler
        }

        var callCount: Int {
            lock.withLock { count }
        }

        /// Sync (non-async) so `NSLock` is legal — Swift 6 forbids `.lock()` in an async scope.
        private func nextIndex() -> Int {
            lock.withLock { count += 1; return count }
        }

        func get(
            url _: URL,
            headers _: [String: String],
            timeout _: TimeInterval
        ) async throws -> HTTPResponse {
            try handler(nextIndex())
        }
    }

    private final class SequenceKeychain: KeychainReading, @unchecked Sendable {
        private let secrets: [Data]
        private let lock = NSLock()
        private var index = 0
        init(_ secrets: [Data]) {
            self.secrets = secrets
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            let value = secrets[Swift.min(index, secrets.count - 1)]
            index += 1
            return value
        }
    }

    private func binding(_ id: String) -> TokenBinding {
        TokenBinding(id: id, configURL: URL(fileURLWithPath: "/tmp/\(id)/config.json"))
    }

    private func token(
        _ bindingID: String,
        value: String? = nil,
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000),
        lastKnown: String
    ) -> DesktopToken {
        DesktopToken(
            token: value ?? "TK-\(bindingID)",
            expiresAt: expiresAt,
            scopes: [CoreConstants.oauthInferenceScope],
            organizationUUID: "org",
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            bindingID: bindingID,
            lastKnownAccountUUID: lastKnown
        )
    }

    private func makeService(
        provider: TokenProvider,
        http: HTTPClient,
        history: UsageHistoryStore
    ) -> UsageService {
        UsageService(
            resolver: AccountResolver(provider: provider),
            client: AnthropicOAuthClient(http: http),
            keyStore: SafeStorageKeyStore(keychain: StubKeychainAlways(Data("pw".utf8))),
            history: history,
            marketingVersion: "1.0"
        )
    }

    private struct StubKeychainAlways: KeychainReading {
        let secret: Data
        init(_ secret: Data) {
            self.secret = secret
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            secret
        }
    }

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
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
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
        #expect(http.callCount == 1)
        #expect(await history.sampleCount(accountUUID: "acct") == 1)
    }

    @Test
    func dedupIssuesOneRequestForSharedAccount() async {
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1", lastKnown: "acct")),
            "p2": .success(token("p2", lastKnown: "acct"))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("p1"), binding("p2")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["p1", "p2"])
        #expect(http.callCount == 1)
    }

    @Test
    func bindingFailuresAreReported() async {
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "ok": .success(token("ok", lastKnown: "acct")),
            "locked": .failure(.keychainUnavailable(.interactionNotAllowed))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("ok"), binding("locked")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.bindingFailures["locked"] == .keychainUnavailable(.interactionNotAllowed))
    }

    // MARK: - Throttle / expiry

    @Test
    func expiredTokenSkipsFetchLoginNeeded() async {
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let history = UsageHistoryStore(path: ":memory:")
        let expired = token("p", expiresAt: Date(timeIntervalSince1970: 1), lastKnown: "acct")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(expired)]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.state == .loginNeeded)
        #expect(http.callCount == 0)
    }

    @Test
    func floorSkipsRefetchWithinWindow() async {
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        let second = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(30)) // < 60s
        #expect(http.callCount == 1)
        if case .stale = second.accounts.first?.state {} else {
            Issue.record("expected stale, got \(String(describing: second.accounts.first?.state))")
        }
    }

    @Test
    func rateLimitedBacksOffAndSkipsWithinWindow() async {
        let http = ScriptedHTTP { _ in
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
        #expect(http.callCount == 1)
        #expect(second.accounts.first?.state == .rateLimited(until: now.addingTimeInterval(120)))
    }

    @Test
    func unauthorizedIsTerminalUntilTokenChanges() async {
        let history = UsageHistoryStore(path: ":memory:")
        let http401 = ScriptedHTTP { _ in HTTPResponse(status: 401, body: Data()) }
        let serviceA = makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http401,
            history: history
        )
        let first = await serviceA.refresh(bindings: [binding("p")], now: now)
        #expect(first.accounts.first?.state == .loginNeeded)
        #expect(http401.callCount == 1)
        // Same token much later → still parked, no new call.
        _ = await serviceA.refresh(bindings: [binding("p")], now: now.addingTimeInterval(100_000))
        #expect(http401.callCount == 1)
        // A different token value (fingerprint change = re-login) → retries.
        let httpOK = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let serviceB = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "NEW", lastKnown: "acct"))]),
            http: httpOK,
            history: history
        )
        let retried = await serviceB.refresh(bindings: [binding("p")], now: now.addingTimeInterval(200_000))
        #expect(httpOK.callCount == 1)
        #expect(retried.accounts.first?.state == .fresh)
    }

    @Test
    func transportFailureIsOffline() async {
        let http = ScriptedHTTP { _ in throw URLError(.notConnectedToInternet) }
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
        let ok = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        _ = await makeService(
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: ok, history: history
        ).refresh(bindings: [binding("p")], now: now)
        // Transport failure > 60s later → offline backoff (with reason .offline).
        let down = ScriptedHTTP { _ in throw URLError(.notConnectedToInternet) }
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
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
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
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
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

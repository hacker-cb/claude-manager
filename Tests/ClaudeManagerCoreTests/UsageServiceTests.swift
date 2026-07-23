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

    // MARK: - Fleet-level key self-heal

    @Test
    func fleetSelfHealInvalidatesKeyWhenAllDecryptsFail() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // config.json encrypted under the CORRECT password.
        let correct = Data("correct-pw".utf8)
        let key = try #require(SafeStorageDecryptor.deriveKey(password: correct))
        let composite = "\(CoreConstants.oauthClientID):org:https://api.anthropic.com:user:inference"
        let cacheJSON = try JSONSerialization.data(withJSONObject: [composite: [
            "token": "TK",
            "expiresAt": 4_000_000_000_000
        ]])
        let blob = SafeStorageDecryptorTests.makeV10Blob(cacheJSON, key: key)
        let configURL = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: [
            CoreConstants.desktopTokenCacheKeyV2: blob.base64EncodedString(),
            CoreConstants.desktopLastAccountKey: "acct"
        ]).write(to: configURL)

        // Keychain hands back the WRONG password first (stale key → all decrypts fail), then the
        // correct one after the fleet self-heal invalidates and retries.
        let keychain = SequenceKeychain([Data("wrong".utf8), correct])
        let keyStore = SafeStorageKeyStore(keychain: keychain)
        let http = ScriptedHTTP { _ in HTTPResponse(status: 200, body: usageBody) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = UsageService(
            resolver: AccountResolver(provider: DesktopSafeStorageProvider(keyStore: keyStore)),
            client: AnthropicOAuthClient(http: http),
            keyStore: keyStore,
            history: history,
            marketingVersion: "1.0"
        )

        let result = await service.refresh(bindings: [TokenBinding(id: "p", configURL: configURL)], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.state == .fresh)
    }
}

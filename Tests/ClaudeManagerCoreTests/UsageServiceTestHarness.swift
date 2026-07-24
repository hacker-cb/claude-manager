import Foundation
import Testing
@testable import ClaudeManagerCore

/// Shared stubs and builders for `UsageServiceTests`. In an extension (and its own file) so the
/// suite body stays about the behaviour under test rather than its scaffolding.
extension UsageServiceTests {
    // MARK: - Harness

    struct StubProvider: TokenProvider {
        let results: [String: Result<DesktopToken, TokenProviderError>]
        func token(
            for binding: TokenBinding,
            interactive _: Bool
        ) async -> Result<DesktopToken, TokenProviderError> {
            results[binding.id] ?? .failure(.configUnreadable)
        }
    }

    /// Records calls **per endpoint**; each call runs `handler(url, callIndex)` (1-based) →
    /// response or throw. Counting per endpoint matters because every account is also identified
    /// via `/profile`, so a bare total would conflate that with the `/usage` call a test means.
    final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var perPath: [String: Int] = [:]
        private let handler: @Sendable (URL, Int) throws -> HTTPResponse

        init(_ handler: @escaping @Sendable (URL, Int) throws -> HTTPResponse) {
            self.handler = handler
        }

        /// Answers `/profile` with a valid identity and `/usage` with `body` — what most tests
        /// want, since they assert on the usage side and only need identification to succeed.
        convenience init(usage body: Data, accountUUID: String = "acct") {
            self.init { url, _ in
                if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                    return HTTPResponse(status: 200, body: Self.profileBody(accountUUID))
                }
                return HTTPResponse(status: 200, body: body)
            }
        }

        static func profileBody(_ uuid: String, email: String = "user@example.com") -> Data {
            Data(#"{"account":{"uuid":"\#(uuid)","email":"\#(email)"}}"#.utf8)
        }

        var callCount: Int {
            lock.withLock { count }
        }

        var usageCallCount: Int {
            lock.withLock { perPath[CoreConstants.usageAPIUsagePath] ?? 0 }
        }

        var profileCallCount: Int {
            lock.withLock { perPath[CoreConstants.usageAPIProfilePath] ?? 0 }
        }

        /// Sync (non-async) so `NSLock` is legal — Swift 6 forbids `.lock()` in an async scope.
        /// Returns the **per-endpoint** 1-based index (not the global total), so a handler can key
        /// on "first `/profile` call" vs "first `/usage` call" without depending on how the two
        /// interleave; `count` still tracks the global total for `callCount`.
        private func record(_ path: String) -> Int {
            lock.withLock {
                count += 1
                perPath[path, default: 0] += 1
                return perPath[path] ?? 1
            }
        }

        func get(
            url: URL,
            headers _: [String: String],
            timeout _: TimeInterval
        ) async throws -> HTTPResponse {
            try handler(url, record(url.path))
        }
    }

    final class SequenceKeychain: KeychainReading, @unchecked Sendable {
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

    func binding(_ id: String) -> TokenBinding {
        TokenBinding(id: id, configURL: URL(fileURLWithPath: "/tmp/\(id)/config.json"))
    }

    func token(
        _ bindingID: String,
        value: String? = nil,
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000)
    ) -> DesktopToken {
        DesktopToken(
            token: value ?? "TK-\(bindingID)",
            expiresAt: expiresAt,
            scopes: [CoreConstants.oauthInferenceScope],
            organizationUUID: "org",
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            bindingID: bindingID
        )
    }

    func makeService(
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

    struct StubKeychainAlways: KeychainReading {
        let secret: Data
        init(_ secret: Data) {
            self.secret = secret
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            secret
        }
    }
}

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

    /// Records call count; each call runs `handler(callIndex)` (1-based) → response or throw.
    final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
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
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000),
        lastKnown: String? = nil
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

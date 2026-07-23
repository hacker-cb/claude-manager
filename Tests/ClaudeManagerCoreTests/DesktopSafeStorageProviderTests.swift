import Foundation
import Testing
@testable import ClaudeManagerCore

struct DesktopSafeStorageProviderTests {
    // MARK: - Harness

    /// Stub keychain: returns a fixed secret, or throws a chosen `KeychainError`.
    private struct StubKeychain: KeychainReading {
        let result: Result<Data, KeychainError>
        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            try result.get()
        }
    }

    /// Returns a different secret on each successive read (last one sticks) — models a
    /// rotated safeStorage password so the self-heal path can be exercised.
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

    private let clientID = CoreConstants.oauthClientID
    private let org = "11111111-2222-3333-4444-555555555555"
    private let password = Data("kc-password".utf8)

    private func inferenceCompositeKey() -> String {
        "\(clientID):\(org):https://api.anthropic.com:user:inference user:file_upload user:profile"
    }

    private func profileCompositeKey() -> String {
        "\(clientID):\(org):https://api.anthropic.com:user:profile"
    }

    /// Write a `config.json` whose `oauth:tokenCacheV2` is the given map, encrypted under the
    /// key derived from `password` (the same the stub keychain returns) — a faithful blob
    /// with no real token.
    private func writeConfig(
        cache: [String: Any],
        lastAccount: String? = nil,
        into dir: URL
    ) throws -> URL {
        let key = SafeStorageDecryptor.deriveKey(password: password)!
        let cacheData = try JSONSerialization.data(withJSONObject: cache)
        let blob = SafeStorageDecryptorTests.makeV10Blob(cacheData, key: key)
        var root: [String: Any] = [CoreConstants.desktopTokenCacheKeyV2: blob.base64EncodedString()]
        if let lastAccount { root[CoreConstants.desktopLastAccountKey] = lastAccount }
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    private func provider(keychain: KeychainReading) -> DesktopSafeStorageProvider {
        DesktopSafeStorageProvider(keyStore: SafeStorageKeyStore(keychain: keychain))
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    // MARK: - Success

    @Test
    func decryptsAndReturnsInferenceToken() async throws {
        try await withTempDir { dir in
            let cache: [String: Any] = [
                inferenceCompositeKey(): [
                    "token": "BEARER-inference-token",
                    "refreshToken": "refresh-xyz",
                    "expiresAt": 1_785_320_075_857,
                    "subscriptionType": "max",
                    "rateLimitTier": "default_claude_max_20x"
                ]
            ]
            let url = try writeConfig(cache: cache, lastAccount: "acct-uuid", into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()

            #expect(token.token == "BEARER-inference-token")
            #expect(token.hasInferenceScope)
            #expect(token.organizationUUID == org)
            #expect(token.subscriptionType == "max")
            #expect(token.rateLimitTier == "default_claude_max_20x")
            #expect(token.lastKnownAccountUUID == "acct-uuid")
            #expect(token.bindingID == "p")
            #expect(abs(token.expiresAt.timeIntervalSince1970 - 1_785_320_075.857) < 0.01)
            #expect(!token.isExpired(now: Date(timeIntervalSince1970: 1_785_000_000)))
        }
    }

    @Test
    func prefersInferenceEntryOverProfileOnly() async throws {
        try await withTempDir { dir in
            let cache: [String: Any] = [
                profileCompositeKey(): ["token": "PROFILE-ONLY", "expiresAt": 1_785_320_075_857],
                inferenceCompositeKey(): ["token": "INFERENCE", "expiresAt": 1_785_320_075_857]
            ]
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "INFERENCE")
            #expect(token.hasInferenceScope)
        }
    }

    @Test
    func fallsBackToProfileOnlyEntry() async throws {
        try await withTempDir { dir in
            let cache: [String: Any] = [
                profileCompositeKey(): ["token": "PROFILE-ONLY", "expiresAt": 1_785_320_075_857]
            ]
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "PROFILE-ONLY")
            #expect(!token.hasInferenceScope)
            #expect(token.hasProfileScope)
        }
    }

    @Test
    func missingExpiresAtIsDistantFuture() async throws {
        try await withTempDir { dir in
            let cache: [String: Any] = [inferenceCompositeKey(): ["token": "T"]]
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.expiresAt == .distantFuture)
            #expect(!token.isExpired())
        }
    }

    // MARK: - Failure modes (all non-fatal)

    @Test
    func missingConfigIsConfigUnreadable() async {
        let url = URL(fileURLWithPath: "/nonexistent/config.json")
        let result = await provider(keychain: StubKeychain(result: .success(password)))
            .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
        #expect(result == .failure(.configUnreadable))
    }

    @Test
    func configWithoutTokenCacheIsNoTokenCache() async throws {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            try Data(#"{"locale":"en-US"}"#.utf8).write(to: url)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.noTokenCache))
        }
    }

    @Test
    func lockedKeychainIsKeychainUnavailable() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let keychain = StubKeychain(result: .failure(.interactionNotAllowed))
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.keychainUnavailable(.interactionNotAllowed)))
        }
    }

    @Test
    func wrongKeyYieldsNonFatalFailure() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            // Keychain hands back a different password → derived key won't decrypt the blob.
            // Usually PKCS7 rejects it (decryptFailed); ~1/256 the padding is coincidentally
            // valid and the garbage isn't JSON (malformedCache). Both are non-fatal — the
            // point is it never succeeds and never crashes.
            let keychain = StubKeychain(result: .success(Data("wrong-password".utf8)))
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            switch result {
            case .failure(.decryptFailed), .failure(.malformedCache): break
            default: Issue.record("expected decryptFailed or malformedCache, got \(result)")
            }
        }
    }

    @Test
    func noMatchingEntryIsNoUsableEntry() async throws {
        try await withTempDir { dir in
            // An entry for a different client with no profile scope → nothing to use.
            let key = "someone-else:\(org):https://api.anthropic.com:user:inference"
            let url = try writeConfig(cache: [key: ["token": "T"]], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.noUsableEntry))
        }
    }

    @Test
    func decryptFailureInvalidatesKeyEnablingSelfHeal() async throws {
        try await withTempDir { dir in
            // config.json is encrypted under the CORRECT password.
            let cache: [String: Any] = [inferenceCompositeKey(): [
                "token": "T",
                "expiresAt": 1_785_320_075_857
            ]]
            let url = try writeConfig(cache: cache, into: dir)
            // Keychain first hands back a WRONG password (stale key → decrypt fails), then
            // the correct one (rotation healed). Without invalidate() the wrong key would
            // stay cached and the second call would fail too.
            let keychain = SequenceKeychain([Data("stale-password".utf8), password])
            let provider = DesktopSafeStorageProvider(keyStore: SafeStorageKeyStore(keychain: keychain))
            let binding = TokenBinding(id: "p", configURL: url)

            let first = await provider.token(for: binding, interactive: false)
            if case .success = first { Issue.record("expected first (stale key) to fail, got \(first)") }

            let second = try await provider.token(for: binding, interactive: false).get()
            #expect(second.token == "T")
        }
    }

    @Test
    func entryWithEmptyTokenIsNoUsableEntry() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": ""]], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.noUsableEntry))
        }
    }
}

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
        into dir: URL
    ) throws -> URL {
        let key = SafeStorageDecryptor.deriveKey(password: password)!
        let cacheData = try JSONSerialization.data(withJSONObject: cache)
        let blob = SafeStorageDecryptorTests.makeV10Blob(cacheData, key: key)
        let root: [String: Any] = [CoreConstants.desktopTokenCacheKeyV2: blob.base64EncodedString()]
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
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()

            #expect(token.token == "BEARER-inference-token")
            #expect(token.hasInferenceScope)
            #expect(token.organizationUUID == org)
            #expect(token.subscriptionType == "max")
            #expect(token.rateLimitTier == "default_claude_max_20x")
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

    @Test
    func electsValidExpiryOverAMalformedSiblingEntry() async throws {
        try await withTempDir { dir in
            let org2 = "99999999-8888-7777-6666-555555555555"
            let malformedKey = "\(clientID):\(org2):https://api.anthropic.com:user:inference user:profile"
            let cache: [String: Any] = [
                // A genuinely valid inference token with a real expiry.
                inferenceCompositeKey(): ["token": "VALID", "expiresAt": 1_785_320_075_857],
                // A sibling inference entry (another org) whose expiresAt is missing — its expiry is
                // unknowable, so it must NOT be treated as the latest and outrank the valid token.
                malformedKey: ["token": "MALFORMED"]
            ]
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "VALID")
        }
    }

    @Test
    func stringEncodedExpiresAtIsParsedNotTreatedAsUnknown() async throws {
        try await withTempDir { dir in
            // Electron has written expiresAt as a JSON string; it must parse to the real date, not
            // fall through to .distantFuture (which would make an expired token look live and rank
            // it as never-expiring in election).
            let cache: [String: Any] = [inferenceCompositeKey(): ["token": "T", "expiresAt": "1785320075857"]]
            let url = try writeConfig(cache: cache, into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(abs(token.expiresAt.timeIntervalSince1970 - 1_785_320_075.857) < 0.01)
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
    func entryWithEmptyTokenIsNoUsableEntry() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": ""]], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.noUsableEntry))
        }
    }
}

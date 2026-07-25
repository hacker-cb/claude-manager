import Foundation
import Testing
@testable import ClaudeManagerCore

struct DesktopSafeStorageProviderTests {
    // MARK: - Harness

    /// Stub keychain: one account under the service, returning a fixed secret or a chosen
    /// `KeychainError`. Enumeration always finds the account (the item exists); the read is what
    /// succeeds or fails — mirroring a present item whose data ACL blocks a background read.
    private struct StubKeychain: KeychainReading {
        let result: Result<Data, KeychainError>
        func accounts(service _: String) throws -> [String] {
            ["Claude"]
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            try result.get()
        }
    }

    /// Stub keychain with a per-account result. `accounts` reports exactly the keys present (an
    /// empty map → no item under the service), and a read of an absent account throws `.notFound`
    /// — so a test can model a machine that stores the password under any one account name, both,
    /// or a name no static list would contain.
    private struct PerAccountKeychain: KeychainReading {
        let byAccount: [String: Result<Data, KeychainError>]
        func accounts(service _: String) throws -> [String] {
            Array(byAccount.keys)
        }

        func secret(service _: String, account: String, interactive _: Bool) throws -> Data {
            try (byAccount[account] ?? .failure(.notFound)).get()
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

    @Test
    func readsTheOnlyAccountUnderTheServiceEvenWhenItIsNotClaude() async throws {
        try await withTempDir { dir in
            // The token cache is encrypted under `password`, which lives under "Claude Key" — the
            // async provider's account name — while "Claude" has no item at all. Enumerating the
            // service finds "Claude Key" and uses it, instead of reporting a missing "Claude".
            let cache: [String: Any] = [inferenceCompositeKey(): [
                "token": "T",
                "expiresAt": 1_785_320_075_857
            ]]
            let url = try writeConfig(cache: cache, into: dir)
            let keychain = PerAccountKeychain(byAccount: ["Claude Key": .success(password)])
            let token = try await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "T")
        }
    }

    @Test
    func readsAnAccountNameNoStaticListWouldContain() async throws {
        try await withTempDir { dir in
            // A hypothetical future provider rename stores the password under an account name we
            // never enumerated by hand. Because resolution keys off the stable *service* and not a
            // fixed account set, it still finds and uses it — this is what "don't guess" buys.
            let cache: [String: Any] = [inferenceCompositeKey(): ["token": "T"]]
            let url = try writeConfig(cache: cache, into: dir)
            let keychain = PerAccountKeychain(byAccount: ["Claude Nightly Key": .success(password)])
            let token = try await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "T")
        }
    }

    @Test
    func noItemUnderTheServiceIsKeychainNotFound() async throws {
        try await withTempDir { dir in
            // Enumeration returns nothing → the item is genuinely absent (Claude never signed in on
            // this machine), which must read as `.notFound` — the state the UI tells the user to fix
            // by signing in, not the "authorize keychain" prompt that can't help.
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let keychain = PerAccountKeychain(byAccount: [:])
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.keychainUnavailable(.notFound)))
        }
    }

    @Test
    func keyStorePicksTheAccountWhoseKeyDecrypts() async throws {
        // "Claude" holds a stale password, "Claude Key" the live one. The store must keep the key
        // the caller's probe accepts — the one that actually decrypts — not the first that reads.
        let live = try #require(SafeStorageDecryptor.deriveKey(password: password))
        let keychain = PerAccountKeychain(byAccount: [
            "Claude": .success(Data("stale-password".utf8)),
            "Claude Key": .success(password)
        ])
        let store = SafeStorageKeyStore(keychain: keychain)
        let resolved = try? await store.key(interactive: false) { $0 == live }
        #expect(resolved == live)
        #expect(await store.isUnlocked)
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

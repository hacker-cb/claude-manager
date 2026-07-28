import Foundation
import Testing
@testable import ClaudeManagerCore

struct DesktopSafeStorageProviderTests {
    // Stored properties only — an extension cannot hold them, and the rest of the scaffolding
    // (stub keychains, the config writer, the temp-dir wrapper) lives in
    // `DesktopSafeStorageProviderTestHarness.swift` so this file stays about the behaviour.
    let clientID = CoreConstants.oauthClientID
    let org = "11111111-2222-3333-4444-555555555555"
    let password = Data("kc-password".utf8)

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
    func interactionNotAllowedIsNotMaskedByALaterNotFound() async throws {
        try await withTempDir { dir in
            // "Claude" (tried first) is present but not yet authorized → .interactionNotAllowed;
            // "Claude Key" (tried later) is gone → .notFound. The fixable state must win, so the UI
            // offers "authorize keychain access" (a Refresh really prompts) — not "item missing".
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let keychain = PerAccountKeychain(byAccount: [
                "Claude": .failure(.interactionNotAllowed),
                "Claude Key": .failure(.notFound)
            ])
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.keychainUnavailable(.interactionNotAllowed)))
        }
    }

    @Test
    func readableAccountThatDoesNotDecryptIsDecryptFailedNotKeychainAuth() async throws {
        try await withTempDir { dir in
            // "Claude" (first) is present but unauthorized → .interactionNotAllowed; "Claude Key"
            // reads fine but its key doesn't decrypt this blob (rotated cache for this binding).
            // The keychain handed us a usable key, so the failure is a decrypt failure — surfacing
            // the sibling's .interactionNotAllowed would tell the user to authorize a key we hold.
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let keychain = PerAccountKeychain(byAccount: [
                "Claude": .failure(.interactionNotAllowed),
                "Claude Key": .success(Data("wrong-readable-password".utf8))
            ])
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            // The point is it's a *decrypt-side* failure (the readable key just doesn't work), not
            // `.keychainUnavailable(.interactionNotAllowed)` from the sibling — which reason of the
            // two (wrong key vs decrypted-but-not-JSON) depends on the stub password is irrelevant.
            switch result {
            case .failure(.decryptFailed), .failure(.malformedCache): break
            default: Issue.record("expected a decrypt-side failure, not keychain-auth, got \(result)")
            }
        }
    }

    @Test
    func notV10BlobIsReportedAsNotV10NotWrongKey() async throws {
        try await withTempDir { dir in
            // A cache whose scheme isn't `v10` (a future format) must surface as
            // `.decryptFailed(.notV10)`, NOT `.decryptFailed(.decryptFailed)` — the latter reads as
            // wrong-key evidence to `UsageService.shouldSelfHeal` and needlessly invalidates the
            // fleet key every poll.
            let notV10 = Data("v20-some-future-scheme-payload-bytes".utf8)
            let root: [String: Any] = [CoreConstants.desktopTokenCacheKeyV2: notV10.base64EncodedString()]
            let url = dir.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.decryptFailed(.notV10)))
        }
    }

    @Test
    func staleAuthorizedAccountDoesNotCauseASecondInteractivePrompt() async throws {
        try await withTempDir { dir in
            let cache: [String: Any] = [inferenceCompositeKey(): [
                "token": "T",
                "expiresAt": 1_785_320_075_857
            ]]
            let url = try writeConfig(cache: cache, into: dir)
            // "Claude" (sorted first) is already authorized — readable in the prompt-free pass — but
            // holds a stale password; "Claude Key" is locked to background reads and live once
            // authorized. Resolution must reject the readable stale account without a prompt and
            // prompt only for "Claude Key" — one dialog, not two.
            let stale = Data("stale-password".utf8)
            let keychain = InteractiveRecordingKeychain([
                "Claude": (background: .success(stale), interactive: .success(stale)),
                "Claude Key": (background: .failure(.interactionNotAllowed), interactive: .success(password))
            ])
            let token = try await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: true).get()
            #expect(token.token == "T")
            #expect(keychain.interactiveReads == ["Claude Key"])
        }
    }

    @Test
    func providerSkipsAStaleAccountAndUsesTheOneThatDecrypts() async throws {
        try await withTempDir { dir in
            // "Claude" (sorted first, tried first) holds a stale password whose derived key does not
            // decrypt this blob to token-cache JSON; "Claude Key" holds the live one. The provider's
            // probe must reject the stale key and fall through — not cache it on a chance PKCS7 unpad.
            let cache: [String: Any] = [inferenceCompositeKey(): [
                "token": "T",
                "expiresAt": 1_785_320_075_857
            ]]
            let url = try writeConfig(cache: cache, into: dir)
            let keychain = PerAccountKeychain(byAccount: [
                "Claude": .success(Data("stale-password".utf8)),
                "Claude Key": .success(password)
            ])
            let token = try await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false).get()
            #expect(token.token == "T")
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
}

// MARK: - Failure modes (all non-fatal)

extension DesktopSafeStorageProviderTests {
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

    // MARK: - Signed out

    @Test
    func anEmptyDecryptedCacheIsSignedOut() async throws {
        try await withTempDir { dir in
            // The on-disk shape Claude Desktop's logout actually writes: the key stays, holding an
            // encrypted `{}` — one 16-byte block. Not `.noTokenCache` (the key is there), not
            // `.noUsableEntry` (there is nothing to match against).
            let url = try writeConfig(cache: [:], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func anEmptyV1CacheIsAlsoSignedOut() async throws {
        try await withTempDir { dir in
            // Logout empties the legacy key too, and a profile old enough to carry only that one
            // must reach the same answer through the v1 fallback.
            let url = try writeConfig(cache: [:], into: dir, key: CoreConstants.desktopTokenCacheKeyV1)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .token(for: TokenBinding(id: "p", configURL: url), interactive: false)
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func theCachedKeyPathAlsoReportsSignedOut() async throws {
        try await withTempDir { dir in
            // Second call onward the key is cached, so the `accepts` probe never runs and the blob
            // is decrypted on the other branch — the one a reading of the probe alone misses.
            let live = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let empty = try writeConfig(cache: [:], into: dir, name: "signed-out.json")
            let subject = provider(keychain: StubKeychain(result: .success(password)))

            _ = try await subject.token(for: TokenBinding(id: "live", configURL: live), interactive: false)
                .get()
            let result = await subject.token(
                for: TokenBinding(id: "out", configURL: empty),
                interactive: false
            )
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func anEmptyCacheStillResolvesTheKeyForItsSiblings() async throws {
        try await withTempDir { dir in
            // `{}` is a valid JSON object, so it satisfies the probe's acceptance test — and it has
            // to keep doing so. A signed-out profile probed first in a fleet must resolve the shared
            // key, not reject it and leave every sibling unable to read its own token.
            let empty = try writeConfig(cache: [:], into: dir, name: "signed-out.json")
            let live = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let subject = provider(keychain: StubKeychain(result: .success(password)))

            let out = await subject.token(for: TokenBinding(id: "out", configURL: empty), interactive: false)
            #expect(out == .failure(.signedOut))
            let token = try await subject
                .token(for: TokenBinding(id: "live", configURL: live), interactive: false).get()
            #expect(token.token == "T")
        }
    }

    @Test
    func aFailedInteractiveReadIsNotMaskedAsInteractionNotAllowed() async throws {
        try await withTempDir { dir in
            // "Claude" needs a prompt on the background pass, then its interactive read fails outright
            // (user-canceled / auth error → `.unexpected`). The stale "needs a prompt" recorded in
            // pass 1 must not mask that: the real keychain error surfaces, not "authorize keychain
            // access" for a prompt the user just dismissed.
            let url = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let keychain = InteractiveRecordingKeychain([
                "Claude": (
                    background: .failure(.interactionNotAllowed),
                    interactive: .failure(.unexpected(-128))
                )
            ])
            let result = await provider(keychain: keychain)
                .token(for: TokenBinding(id: "p", configURL: url), interactive: true)
            #expect(result == .failure(.keychainUnavailable(.unexpected(-128))))
        }
    }
}

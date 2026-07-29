import Foundation
import Testing
@testable import ClaudeManagerCore

/// The signed-out and corrupt-cache verdicts. Their own file — the suite's main body was over the
/// 500-line limit, and these tests are one coherent group: everything about how the provider reads
/// a cache that is present but holds no usable login.
extension DesktopSafeStorageProviderTests {
    @Test
    func anEmptyDecryptedCacheIsSignedOut() async throws {
        try await withTempDir { dir in
            // The on-disk shape Claude Desktop's logout actually writes: the key stays, holding an
            // encrypted `{}` — one 16-byte block. Not `.noTokenCache` (the key is there), not
            // `.noUsableEntry` (there is nothing to match against).
            let url = try writeConfig(cache: [:], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
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
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
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

            _ = try await subject.read(TokenBinding(id: "live", configURL: live), interactive: false).token
                .get()
            let result = await subject.read(
                TokenBinding(id: "out", configURL: empty),
                interactive: false
            ).token
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func anEmptyCacheStillElectsTheRightKeyForItsSiblings() async throws {
        try await withTempDir { dir in
            // `{}` is a valid JSON object, so it satisfies the probe's acceptance test — and it has
            // to keep doing so. A signed-out profile probed first in a fleet must resolve the shared
            // key, not reject it and leave every sibling unable to read its own token.
            //
            // Two keychain accounts, only the second holding the live password (the store sorts, so
            // "Claude" is probed before "Claude Key"): the empty blob has to reject the stale
            // candidate and elect the live one. `isUnlocked` is the assertion that can actually
            // fail — a probe that refused `{}` would cache nothing and leave the store locked.
            let empty = try writeConfig(cache: [:], into: dir, name: "signed-out.json")
            let live = try writeConfig(cache: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let store = SafeStorageKeyStore(keychain: PerAccountKeychain(byAccount: [
                "Claude": .success(Data("stale-password".utf8)),
                "Claude Key": .success(password)
            ]))
            let subject = DesktopSafeStorageProvider(keyStore: store)

            let out = await subject.read(TokenBinding(id: "out", configURL: empty), interactive: false).token
            #expect(out == .failure(.signedOut))
            #expect(await store.isUnlocked)
            // And the key it cached is the live one, not the stale sibling's.
            let token = try await subject
                .read(TokenBinding(id: "live", configURL: live), interactive: false).token.get()
            #expect(token.token == "T")
        }
    }

    @Test
    func bothCacheKeysEmptyIsStillSignedOut() async throws {
        try await withTempDir { dir in
            // The shape a real logout leaves: Desktop empties v2 *and* v1, so there is no unread
            // sibling that could hold a live token and the sign-in remedy is safe to name.
            let url = try writeConfig(v2: [:], v1: [:], into: dir)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func anUndecryptableV2BesideALiveV1YieldsTheV1Token() async throws {
        try await withTempDir { dir in
            // Decodable base64, but not a v10 blob — the shape a partial write or a sync conflict
            // leaves. Judging the key by the first blob alone meant this rejected every keychain
            // account and condemned the binding, with a perfectly good v1 unread in the same file.
            let url = try writeConfig(
                rawV2: Data("not-a-v10-blob!!".utf8).base64EncodedString(),
                v1: [inferenceCompositeKey(): ["token": "T"]],
                into: dir
            )
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token.get()
            #expect(token.token == "T")
        }
    }

    @Test
    func anEmptyV2BesideAPopulatedV1YieldsTheV1Token() async throws {
        try await withTempDir { dir in
            // v2 is read first but holds nothing, and the entries are in the legacy key. Neither
            // presence nor decodability can tell which key is live, so an empty one is not the
            // answer — it is a reason to read the other. Reporting a signed-in profile as signed
            // out sends the user to sign in again to no effect; reporting it as unavailable buries
            // a token that is right there and already decryptable with the key in hand.
            let url = try writeConfig(v2: [:], v1: [inferenceCompositeKey(): ["token": "T"]], into: dir)
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token.get()
            #expect(token.token == "T")
        }
    }

    @Test
    func aCorruptV2FallsBackToTheDecodableV1() async throws {
        try await withTempDir { dir in
            // v2 is elected over v1 by decodability, not presence: a partially written v2 beside a
            // live v1 used to report a broken cache while a usable token sat two keys away in the
            // same file, already read into a local.
            let url = try writeConfig(
                rawV2: "not-base64!!",
                v1: [inferenceCompositeKey(): ["token": "T"]],
                into: dir
            )
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token.get()
            #expect(token.token == "T")
        }
    }

    // MARK: - Which cache is allowed to speak

    /// A password no keychain in these tests holds — so a cache encrypted under it is present,
    /// well-formed, and unreadable, which is the only way to model a key rotation from outside.
    private var rotatedAway: Data {
        Data("pre-rotation-password".utf8)
    }

    @Test
    func anEmptyLegacyCacheCannotSignOutAProfileWhoseLiveCacheWeCouldNotRead() async throws {
        try await withTempDir { dir in
            // v2 — the cache that would say whether this profile is signed in — is encrypted under
            // a key we no longer have. The only thing readable is a legacy `{}` from some logout in
            // the past, and it used to be allowed to answer for the login: `.signedOut`.
            //
            // That is a positive claim about a login we never managed to look at. It costs the row
            // its figures, detaches it from its account, and tells a signed-in user to sign in —
            // and it buries the `.decryptFailed` that `UsageService.shouldSelfHeal` needs in order
            // to recover a whole fleet from a rotated key, which is the situation that produces
            // this shape in the first place.
            let url = try writeConfig(
                v2: [inferenceCompositeKey(): ["token": "T"]], v2Password: rotatedAway,
                v1: [:], v1Password: password,
                into: dir
            )
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
            // Either decrypt-side verdict is legitimate for a key that is simply wrong — it unpads
            // cleanly on garbage often enough that which one surfaces depends on the stub password,
            // as `keychainReadFailureIsNotMisreadAsAnAuthorizationProblem` already records. The
            // claim here is "the blob defeated us, and we said so".
            switch result {
            case .failure(.decryptFailed), .failure(.malformedCache): break
            default: Issue.record("expected a decrypt-side failure, got \(result)")
            }
        }
    }

    @Test
    func anEmptyLiveCacheIsStillASignOutBesideAnUnreadableLegacyOne() async throws {
        try await withTempDir { dir in
            // The mirror image, and the reason the rule discriminates by *which* cache spoke rather
            // than treating any failure as disqualifying: here the live cache decrypted and is
            // empty, so the sign-out is a fact. A legacy blob stranded by an old key rotation is
            // history, and must not turn a real logout into "source unavailable" — which would put
            // an unclearable orange fault on a row whose condition is normal.
            let url = try writeConfig(
                v2: [:], v2Password: password,
                v1: [inferenceCompositeKey(): ["token": "T"]], v1Password: rotatedAway,
                into: dir
            )
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
            #expect(result == .failure(.signedOut))
        }
    }

    @Test
    func aForeignEntryInTheLiveCacheDoesNotBuryAUsableLegacyToken() async throws {
        try await withTempDir { dir in
            // Both caches decrypt. v2 holds entries but none of them ours — another OAuth client's,
            // or an organization the user has left — while v1 holds a usable token. Election used to
            // run on the first populated cache alone and report `.noUsableEntry` on its refusal,
            // with the token sitting decrypted in a local two keys away. Every populated cache now
            // gets a turn, for exactly the reason both keys are read at all.
            let url = try writeConfig(
                v2: ["someone:elses:entry": ["token": "T"]],
                v1: [inferenceCompositeKey(): ["token": "USABLE"]],
                into: dir
            )
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token.get()
            #expect(token.token == "USABLE")
        }
    }

    @Test
    func anEmptyTokenInTheLiveCacheDoesNotBuryAUsableLegacyToken() async throws {
        try await withTempDir { dir in
            // The same defect one guard further down, which is why the two checks are now one step:
            // v2's elected entry *is* ours and simply carries no token string. Election matched, so
            // the cache was never "nothing of ours" — it is a usable-looking entry that turns out to
            // be empty, and the sibling never got a turn.
            let url = try writeConfig(
                v2: [inferenceCompositeKey(): ["token": ""]],
                v1: [inferenceCompositeKey(): ["token": "USABLE"]],
                into: dir
            )
            let token = try await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token.get()
            #expect(token.token == "USABLE")
        }
    }

    @Test
    func nothingUsableInAnyCacheIsStillNoUsableEntry() async throws {
        try await withTempDir { dir in
            // The verdict keeps its meaning — "entries exist, none of them ours" — it just now says
            // it about the whole profile instead of one of its caches. It must survive, because it is
            // the one no-token state that deliberately offers no sign-in remedy.
            let url = try writeConfig(
                v2: ["someone:elses:entry": ["token": "T"]],
                v1: ["another:clients:entry": ["token": "T"]],
                into: dir
            )
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
            #expect(result == .failure(.noUsableEntry))
        }
    }

    @Test
    func anUndecodableCacheValueIsCorruptNotAbsent() async throws {
        try await withTempDir { dir in
            // The key is there, its value is not base64. That is a damaged config, not a profile
            // nobody signed into — and the two must not share a code now that `.noTokenCache`
            // offers a sign-in and drops the binding out of its account's fan-out.
            let url = dir.appendingPathComponent("config.json")
            try Data(#"{"oauth:tokenCacheV2":"not-base64!!"}"#.utf8).write(to: url)
            let result = await provider(keychain: StubKeychain(result: .success(password)))
                .read(TokenBinding(id: "p", configURL: url), interactive: false).token
            #expect(result == .failure(.malformedCache))
        }
    }
}

import Foundation
import Testing
@testable import ClaudeManagerCore

/// The plaintext account hint, and the one property that makes reading it worth anything: it has
/// to survive the failure it is meant to explain.
///
/// A binding whose blob would not decrypt used to lose its account entirely, because a reason was
/// all the failure arm could carry — while the file we had just parsed named that account in the
/// clear. Each test below is one of the ways the token can fail, asserting the hint comes back
/// anyway. Nothing consumes it yet; that is the next commit's job.
extension DesktopSafeStorageProviderTests {
    private var hint: String {
        "80d91625-5c43-48ab-9892-3d6496250958"
    }

    private func read(_ url: URL, keychain: KeychainReading) async -> BindingReading {
        await provider(keychain: keychain)
            .read(TokenBinding(id: "p", configURL: url), interactive: false)
    }

    @Test
    func aReadableTokenComesBackWithItsHint() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(
                cache: [inferenceCompositeKey(): ["token": "T"]],
                into: dir,
                hint: hint
            )
            let reading = await read(url, keychain: StubKeychain(result: .success(password)))
            #expect(try reading.token.get().token == "T")
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aSignedOutProfileStillNamesTheAccountItLost() async throws {
        try await withTempDir { dir in
            // The shape that motivated all of this: logout rewrites the cache as an encrypted `{}`
            // and leaves `lastKnownAccountUuid` in place, so the profile can still say whose login
            // it was — with no keychain of its own to unlock and no network to ask.
            let url = try writeConfig(cache: [:], into: dir, hint: hint)
            let reading = await read(url, keychain: StubKeychain(result: .success(password)))
            #expect(reading.token == .failure(.signedOut))
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aRefusedKeychainDoesNotCostTheAccountName() async throws {
        try await withTempDir { dir in
            // The most common failure by far, and the one where losing the name is least excusable:
            // the profile is signed in, we simply were not allowed to read its token this pass.
            let url = try writeConfig(
                cache: [inferenceCompositeKey(): ["token": "T"]],
                into: dir,
                hint: hint
            )
            let reading = await read(url, keychain: StubKeychain(result: .failure(.interactionNotAllowed)))
            #expect(reading.token == .failure(.keychainUnavailable(.interactionNotAllowed)))
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aWrongKeyDoesNotCostTheAccountName() async throws {
        try await withTempDir { dir in
            // A rotated safeStorage key fails every profile at once. The hint is plaintext, so it
            // is exactly the signal that survives a rotation — the fleet can still be described
            // while none of it can be read.
            let url = try writeConfig(
                cache: [inferenceCompositeKey(): ["token": "T"]],
                into: dir,
                hint: hint
            )
            let stale = StubKeychain(result: .success(Data("stale-password".utf8)))
            let reading = await read(url, keychain: stale)
            // Either decrypt-side verdict is legitimate for a wrong key — it unpads cleanly on
            // garbage often enough that which one comes out depends on the stub password, as
            // `keychainReadFailureIsNotMisreadAsAnAuthorizationProblem` already records. The claim
            // here is about the hint, so the token arm is pinned only to "the blob defeated us".
            switch reading.token {
            case .failure(.decryptFailed), .failure(.malformedCache): break
            default: Issue.record("expected a decrypt-side failure, got \(reading.token)")
            }
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aCorruptCacheDoesNotCostTheAccountName() async throws {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let root: [String: Any] = [
                CoreConstants.desktopTokenCacheKeyV2: "not-base64!!",
                CoreConstants.desktopAccountHintKey: hint
            ]
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let reading = await read(url, keychain: StubKeychain(result: .success(password)))
            #expect(reading.token == .failure(.malformedCache))
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aCacheHoldingNoEntryOfOursDoesNotCostTheAccountName() async throws {
        try await withTempDir { dir in
            let url = try writeConfig(cache: ["someone:elses:entry": ["token": "T"]], into: dir, hint: hint)
            let reading = await read(url, keychain: StubKeychain(result: .success(password)))
            #expect(reading.token == .failure(.noUsableEntry))
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func aProfileNobodyEverSignedIntoCanStillNameAnAccount() async throws {
        try await withTempDir { dir in
            // No cache key at all, but a hint — the shape a profile takes after Desktop has written
            // the account it saw and before (or without) any token landing in the file.
            let url = dir.appendingPathComponent("config.json")
            let root: [String: Any] = [CoreConstants.desktopAccountHintKey: hint]
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let reading = await read(url, keychain: StubKeychain(result: .success(password)))
            #expect(reading.token == .failure(.noTokenCache))
            #expect(reading.hintedAccountUUID == hint)
        }
    }

    @Test
    func anUnreadableConfigHasNoHintToGive() async throws {
        try await withTempDir { dir in
            // The one failure that costs the hint too, and correctly: there is no file to have
            // hinted anything. A launcher created and never opened lands here.
            let reading = await read(
                dir.appendingPathComponent("nothing.json"),
                keychain: StubKeychain(result: .success(password))
            )
            #expect(reading.token == .failure(.configUnreadable))
            #expect(reading.hintedAccountUUID == nil)
        }
    }

    @Test
    func aHintThatIsNotAUuidIsDropped() async throws {
        try await withTempDir { dir in
            // This value reaches a dictionary key and an identity lookup. A `config.json` written
            // by some future Desktop — or half-written by a crash — must not be able to put an
            // arbitrary string there, so it is parsed rather than trusted.
            //
            // The 36-character case is the one that matters: a length test would take it, and the
            // name of this test would then be a lie.
            let wrongLength = ["", "nope", String(repeating: "x", count: 37)]
            let rightLengthWrongShape = [
                String(repeating: "x", count: 36),
                "80d91625X5c43-48ab-9892-3d6496250958",
                "80d91625-5c43-48ab-9892-3d64962509\u{00E9}"
            ]
            for bad in wrongLength + rightLengthWrongShape {
                let url = try writeConfig(cache: [:], into: dir, hint: bad)
                #expect(
                    await read(url, keychain: StubKeychain(result: .success(password)))
                        .hintedAccountUUID == nil,
                    "accepted \(bad.debugDescription)"
                )
            }
            // Not a string at all — a JSON number where a uuid was expected.
            let url = dir.appendingPathComponent("number.json")
            let root: [String: Any] = [CoreConstants.desktopAccountHintKey: 42]
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            #expect(await read(url, keychain: StubKeychain(result: .success(password)))
                .hintedAccountUUID == nil)
        }
    }
}

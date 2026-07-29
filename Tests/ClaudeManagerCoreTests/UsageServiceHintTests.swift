import Foundation
import Testing
@testable import ClaudeManagerCore

/// The hint's route through a whole pass — where it comes from, and what it is still not allowed to
/// touch once it is in the service's hands.
extension UsageServiceTests {
    @Test
    func aHintIsNamedFromTheLocalAccountRecordWithNoCallAndNoWrite() async {
        // The common shape: one launcher per login, so a signed-out profile has no live sibling to
        // borrow a name from. `account_profiles` is the local record of every `/oauth/profile`
        // answer this machine has stored, and it answers with no keychain, no network — and, the
        // point of this test, no trace: attaching a row must not create a throttle window or a
        // sample under the account it names, or the next real fetch for that login would be gated
        // by a floor it never earned.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        await history.setProfile(
            AccountIdentity(uuid: "acct-stored", email: "was@example.com"),
            tokenFingerprint: "some-old-token",
            fetchedAt: now.addingTimeInterval(-90 * 86400)
        )
        let service = makeService(
            provider: StubProvider(results: ["out": .failure(.signedOut)], hints: ["out": "acct-stored"]),
            http: http,
            history: history
        )

        let result = await service.refresh(bindings: [binding("out")], now: now)

        #expect(result.hintedAccounts["out"]?.email == "was@example.com")
        #expect(http.callCount == 0)
        #expect(await history.throttle(scope: UsageService.usageScope("acct-stored")) == nil)
        #expect(await history.sampleCount(accountUUID: "acct-stored") == 0)
    }

    @Test
    func aHintNamingAnAccountNothingKnowsAboutIsDropped() async {
        // The property that bounds how wrong a stale hint can be: it may only ever point at a login
        // something else already knows about, so it can misattribute a row to a real account and
        // can never invent one out of a uuid.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["out": .failure(.signedOut)], hints: ["out": "never-seen"]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("out")], now: now)
        #expect(result.hintedAccounts.isEmpty)
    }

    @Test
    func aHintIsNamedFromThisPassInPreferenceToTheStoredRecord() async {
        // The source order, pinned by making the two sources *disagree*: a stored row for the same
        // account carries an old e-mail, and this pass's `/oauth/profile` answer carries the current
        // one. Seeded the other way round the test could not fail, because both sources would hand
        // back the same string and either order would satisfy it.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct")
        let history = UsageHistoryStore(path: ":memory:")
        await history.setProfile(
            AccountIdentity(uuid: "acct", email: "renamed-away@example.com"),
            tokenFingerprint: "some-old-token",
            fetchedAt: now.addingTimeInterval(-86400)
        )
        let service = makeService(
            provider: StubProvider(
                results: ["live": .success(token("live")), "out": .failure(.signedOut)],
                hints: ["out": "acct"]
            ),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("live"), binding("out")], now: now)
        #expect(result.hintedAccounts["out"]?.email == "user@example.com")
        // One login, one `/usage` call — the attached row costs nothing extra.
        #expect(http.usageCallCount == 1)
    }

    @Test
    func aFleetThatOnlyHintsCanStillHealARotatedKey() async {
        // The trap this design exists to avoid. `shouldSelfHeal` requires that *nothing* resolved;
        // if a hint could mint an account, a machine whose safeStorage key had rotated would show a
        // full account list beside an empty token set, and the fleet-wide key recovery would stop
        // firing — silently, with every profile serving stale forever and no diagnostic anywhere.
        // Hints ride a separate channel precisely so this stays true.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let rotated = TokenProviderError.decryptFailed(.decryptFailed)
        let provider = CountingProvider(
            results: ["a": .failure(rotated), "b": .failure(rotated)],
            hints: ["a": "acct-stored", "b": "acct-stored"]
        )
        await history.setProfile(
            AccountIdentity(uuid: "acct-stored", email: "was@example.com"),
            tokenFingerprint: "some-old-token",
            fetchedAt: now
        )
        let service = makeService(provider: provider, http: http, history: history)

        _ = await service.refresh(bindings: [binding("a"), binding("b")], now: now)

        // Two reads per binding: the key was invalidated once and the whole fleet re-resolved.
        #expect(provider.reads == ["a": 2, "b": 2])
    }
}

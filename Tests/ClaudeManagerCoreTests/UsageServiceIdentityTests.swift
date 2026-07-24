import Foundation
import Testing
@testable import ClaudeManagerCore

/// Identity reconciliation: how a token becomes an account via `/profile`, how siblings fold,
/// and how distinct tokens are kept apart. In its own file so the main suite stays under the
/// type-length limit.
extension UsageServiceTests {
    // MARK: - Identity reconciliation

    @Test
    func provisionalIdentityIsReconciledViaProfile() async {
        // Before `/profile` the account is keyed only by its token fingerprint; the service must
        // settle it via `/profile` before storing anything under the authoritative account uuid.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct-real")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.identity.uuid == "acct-real")
        #expect(result.accounts.first?.identity.email == "user@example.com")
        #expect(result.accounts.first?.state == .fresh)
        #expect(http.profileCallCount == 1)
        #expect(http.usageCallCount == 1)
        // Persisted under the authoritative uuid — not the binding id it started with.
        #expect(await history.sampleCount(accountUUID: "acct-real") == 1)
        #expect(await history.sampleCount(accountUUID: "p") == 0)
    }

    @Test
    func launchersSharingOneLoginCollapseToOneAccount() async {
        // Three launchers, one login, wanting three windows. Each carries its own token, so
        // nothing local ties them together — only `/profile` can prove the same account, and it
        // must settle that before any usage is fetched, or one account is billed as three.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "one-account")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1")),
            "p2": .success(token("p2")),
            "p3": .success(token("p3"))
        ]), http: http, history: history)
        let result = await service.refresh(
            bindings: [binding("p1"), binding("p2"), binding("p3")],
            now: now
        )
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["p1", "p2", "p3"])
        #expect(result.accounts.first?.state == .fresh)
        #expect(http.usageCallCount == 1) // one account → one /usage, however many launchers
        // One identity lookup per token is unavoidable: that IS what reveals the shared account.
        #expect(http.profileCallCount == 3)
        #expect(await history.sampleCount(accountUUID: "one-account") == 1)
    }

    @Test
    func reLoginToADifferentAccountIsNotMisidentifiedAsThePrevious() async {
        // A launcher signed out and back into a *different* account gets a new token, hence a new
        // fingerprint. The previous account's cached `/profile` (keyed by the old fingerprint) must
        // NOT be reused for it — the unseen fingerprint confirms authoritatively via its own
        // `/profile`, or its usage would be filed under, and shown as, the wrong account.
        let history = UsageHistoryStore(path: ":memory:")

        // Pass 1: signed into acctA. Caches acctA's identity (by acctA's token fingerprint).
        let http1 = ScriptedHTTP(usage: usageBody, accountUUID: "acctA")
        let s1 = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-old"))]),
            http: http1, history: history
        )
        let r1 = await s1.refresh(bindings: [binding("p")], now: now)
        #expect(r1.accounts.first?.identity.uuid == "acctA")

        // Pass 2: same launcher, a *new* token (re-login to acctB).
        let http2 = ScriptedHTTP(usage: usageBody, accountUUID: "acctB")
        let s2 = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-new"))]),
            http: http2, history: history
        )
        let r2 = await s2.refresh(bindings: [binding("p")], now: now.addingTimeInterval(120))
        #expect(r2.accounts.first?.identity.uuid == "acctB") // authoritative, not the previous cache
        #expect(http2.profileCallCount == 1) // the unseen fingerprint forced a fresh lookup
        #expect(await history.sampleCount(accountUUID: "acctB") == 1)
    }

    @Test
    func profileFailureKeepsProvisionalIdentity() async {
        // `/profile` unreachable → keep the provisional key (the token fingerprint) rather than
        // dropping the account; usage still works, just keyed by fingerprint until a later poll
        // settles the authoritative uuid.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 500, body: Data())
            }
            return HTTPResponse(status: 200, body: usageBody)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let tok = token("p")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(tok)]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.identity.uuid == tok.fingerprint)
        #expect(result.accounts.first?.state == .fresh)
        #expect(await history.sampleCount(accountUUID: tok.fingerprint) == 1)
    }

    @Test
    func tokensBelongingToDifferentAccountsAreNeverMerged() async {
        // The misattribution guard behind the fingerprint-grouping design: two bindings a local
        // signal (a shared org, or the old config hint) might have collapsed, but whose tokens
        // `/profile` proves belong to *different* accounts, must resolve to two accounts — never
        // one account's usage shown for both. `/profile` answers acct-A then acct-B by call order
        // (identity settles before any `/usage`).
        let body = usageBody
        let http = ScriptedHTTP { url, index in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(
                    status: 200,
                    body: ScriptedHTTP.profileBody(index == 1 ? "acct-A" : "acct-B")
                )
            }
            return HTTPResponse(status: 200, body: body)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1")),
            "p2": .success(token("p2"))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("p1"), binding("p2")], now: now)
        #expect(result.accounts.count == 2) // not merged
        #expect(Set(result.accounts.map(\.identity.uuid)) == ["acct-A", "acct-B"])
        #expect(http.usageCallCount == 2) // two accounts → two usage calls
    }

    @Test
    func storedProfileIsReusedInsteadOfRefetched() async {
        // The name is cached (by token fingerprint), so a second pass costs no extra /profile
        // call. The uuid is `/profile`'s answer — the authoritative source of which account a
        // token belongs to.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct-authoritative")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        // Past the 60s floor so the second pass genuinely fetches usage again.
        let later = now.addingTimeInterval(120)
        let result = await service.refresh(bindings: [binding("p")], now: later)
        #expect(result.accounts.first?.identity.uuid == "acct-authoritative")
        #expect(result.accounts.first?.identity.email == "user@example.com")
        #expect(http.usageCallCount == 2)
        #expect(http.profileCallCount == 1) // fetched once, reused after
    }

    @Test
    func staleProfileIsRefetchedAfterTTL() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        let afterTTL = now.addingTimeInterval(UsageService.profileTTLSeconds + 60)
        _ = await service.refresh(bindings: [binding("p")], now: afterTTL)
        #expect(http.profileCallCount == 2) // the day-old answer is re-asked, not trusted
    }
}

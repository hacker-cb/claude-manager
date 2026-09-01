import Foundation
import Testing
@testable import ClaudeManagerCore

/// The gates that decide when a call may go out at all — expiry, the terminal park, the 60s
/// floor, and the fleet key self-heal. In their own file so the main suite stays under the
/// type-length limit.
extension UsageServiceTests {
    @Test
    func profileRejectionDoesNotCancelTheUsageCall() async {
        // A token `/usage` accepts but `/profile` rejects (no `user:profile` scope, or an org that
        // restricts it). The identity park must stay in its own scope: sharing one made a 403 on a
        // cosmetic name lookup silently stop usage for an account that works.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 403, body: Data())
            }
            return HTTPResponse(status: 200, body: usageBody)
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.state == .fresh)
        #expect(result.accounts.first?.snapshot?.weeklyAll?.utilization == 0.5)
        #expect(http.usageCallCount == 1)
        // And the rejection is remembered for the length of its finite park, so the next tick
        // doesn't re-ask for the name…
        let inside = now.addingTimeInterval(UsageService.terminalBackoffSeconds - 60)
        _ = await service.refresh(bindings: [binding("p")], now: inside)
        #expect(http.profileCallCount == 1)
        // …while once it runs out the name is asked for again — a park is finite, not a verdict.
        let after = now.addingTimeInterval(UsageService.terminalBackoffSeconds + 61)
        _ = await service.refresh(bindings: [binding("p")], now: after)
        #expect(http.profileCallCount == 2)
    }

    @Test
    func interactiveRefreshRetriesImmediatelyAfterATerminalPark() async {
        // The floor's `lastAttemptAt` is written by the very 401 being cleared, so leaving it in
        // force made the documented exit a no-op for its first minute.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            return HTTPResponse(status: 401, body: Data())
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        let first = await service.refresh(bindings: [binding("p")], now: now)
        #expect(first.accounts.first?.state == .loginNeeded)
        // Five seconds later — well inside the 60s floor — the user presses Refresh.
        let soon = now.addingTimeInterval(5)
        let second = await service.refresh(bindings: [binding("p")], now: soon, interactive: true)
        #expect(http.usageCallCount == 2) // it actually retried
        #expect(second.accounts.first?.state == .loginNeeded) // and stayed honest about the result
    }

    @Test
    func siblingLaunchersFoldToOneAccountAndOneUsageCall() async {
        // Two launchers on one login hold different tokens, so each confirms its account via its
        // own `/profile` (the authoritative, safe signal) — then they fold into one account by that
        // uuid and share a single `/usage` call. The old account-keyed shortcut saved the second
        // `/profile` but rested on a config hint that could point a token at the wrong account.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1")),
            "p2": .success(token("p2"))
        ]), http: http, history: history)
        let result = await service.refresh(bindings: [binding("p1"), binding("p2")], now: now)
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["p1", "p2"])
        #expect(http.profileCallCount == 2) // one per distinct token — that is what folds them
        #expect(http.usageCallCount == 1) // …into one account, one usage call
    }

    @Test
    func deadTokenStopsBeingOfferedToProfile() async {
        // A provisional binding whose login is dead: /profile 401s. That must park the account,
        // not repeat forever — the gates live in the usage path, which runs after identity and
        // cannot un-send a call the identity pass already made.
        let http = ScriptedHTTP { _, _ in HTTPResponse(status: 401, body: Data()) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http.profileCallCount == 1)
        // Minutes later, inside the park — no second identity attempt, no usage attempt.
        let later = now.addingTimeInterval(UsageService.terminalBackoffSeconds - 60)
        let second = await service.refresh(bindings: [binding("p")], now: later)
        #expect(http.profileCallCount == 1)
        #expect(second.accounts.first?.state == .loginNeeded)
    }

    @Test
    func expiredTokenIsNeverOfferedToProfile() async {
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let expired = token("p", expiresAt: Date(timeIntervalSince1970: 1))
        let service = makeService(
            provider: StubProvider(results: ["p": .success(expired)]),
            http: http,
            history: history
        )
        let result = await service.refresh(bindings: [binding("p")], now: now)
        #expect(result.accounts.first?.state == .loginNeeded)
        #expect(http.callCount == 0) // not /usage, and not /profile either
    }

    @Test
    func manualRefreshClearsATerminalParkButABackoffSurvivesIt() async {
        // 401 parks the account. The documented exits are a re-login or an explicit Refresh, so
        // the interactive pass must retry — otherwise the button is a no-op forever.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            return HTTPResponse(status: 401, body: Data())
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)
        // A later *background* pass inside the park stays parked…
        let later = now.addingTimeInterval(UsageService.terminalBackoffSeconds - 60)
        _ = await service.refresh(bindings: [binding("p")], now: later)
        #expect(http.usageCallCount == 1)
        // …an explicit Refresh tries again without waiting the park out.
        _ = await service.refresh(bindings: [binding("p")], now: later, interactive: true)
        #expect(http.usageCallCount == 2)
    }

    @Test
    func anExplicitRefreshDoesNotLiftARateLimitBackoff() async {
        // The interactive exit is documented for a **terminal** park only, and the test above only
        // ever exercised that half — its handler 401s every call, so nothing there could have
        // noticed the rule going the other way. A 429 window belongs to the server: honouring the
        // button inside it would re-issue a call against an endpoint that had just told us to stop.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            return HTTPResponse(status: 429, body: Data(), headers: ["retry-after": "600"])
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)

        let inside = now.addingTimeInterval(300) // past the 60s floor, well inside the 600s window
        let result = await service.refresh(bindings: [binding("p")], now: inside, interactive: true)
        #expect(http.usageCallCount == 1)
        #expect(result.accounts.first?.state == .rateLimited)
    }

    @Test
    func anExplicitRefreshDoesNotLiftAnOfflineBackoff() async {
        // Same rule, the other non-terminal reason. A network that is down is not something the
        // user's button can argue with, and retrying on every press would strip the exponential
        // backoff exactly when the machine is least able to pay for it.
        let http = ScriptedHTTP { _, _ in throw URLError(.notConnectedToInternet) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)

        let inside = now.addingTimeInterval(120) // past the floor, inside the 300s default backoff
        let result = await service.refresh(bindings: [binding("p")], now: inside, interactive: true)
        #expect(http.usageCallCount == 1)
        // No stored sample to serve, so the parked state renders as offline rather than stale.
        #expect(result.accounts.first?.state == .offline)
    }

    @Test
    func selfHealIsDecidedByWhatResolvedNotByFailuresAlone() async {
        // `shouldSelfHeal` is two clauses, and only one of them had a test: `shouldSelfHealForTest`
        // hardcodes an empty account list, so every assertion above is about the *evidence* clause.
        // The other one — that nothing resolved at all — is what stops a single corrupt blob from
        // invalidating a key that decrypts the rest of the fleet, on every tick, forever.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let provider = CountingProvider(results: [
            "live": .success(token("live")),
            "rotated": .failure(.decryptFailed(.decryptFailed))
        ])
        let service = makeService(provider: provider, http: http, history: history)
        _ = await service.refresh(bindings: [binding("live"), binding("rotated")], now: now)

        // One read per binding. A self-heal would have invalidated the shared key and resolved the
        // whole fleet a second time, which is what these counts would show.
        #expect(provider.reads == ["live": 1, "rotated": 1])
    }

    @Test
    func aChangedElectedTokenDoesNotDiscardARateLimitBackoff() async {
        // Sibling launchers on one account re-elect a token whenever any of them refreshes its
        // own, with no re-login involved. That must not read as one and drop a 429 window.
        let http = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            return HTTPResponse(status: 429, body: Data(), headers: ["retry-after": "600"])
        }
        let history = UsageHistoryStore(path: ":memory:")
        let first = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-A"))]),
            http: http,
            history: history
        )
        _ = await first.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)
        // Same account, different elected token → different fingerprint, still inside the window.
        let second = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-B"))]),
            http: http,
            history: history
        )
        let result = await second.refresh(bindings: [binding("p")], now: now.addingTimeInterval(120))
        #expect(http.usageCallCount == 1) // the 600s backoff held
        if case .rateLimited = result.accounts.first?.state {} else {
            Issue.record("expected rateLimited, got \(String(describing: result.accounts.first?.state))")
        }
    }

    @Test
    func selfHealSurvivesABindingThatSimplyIsNotSignedIn() {
        // The default-account binding is always present and is permanently `.noTokenCache` for
        // anyone who only uses launchers. Requiring *every* failure to be crypto-related let that
        // one binding disable key-rotation recovery for the whole fleet.
        let rotated = TokenProviderError.decryptFailed(.decryptFailed)
        #expect(UsageService.shouldSelfHealForTest(failures: ["a": rotated, "b": .noTokenCache]))
        // A blob-shape problem is not wrong-key evidence: re-deriving the key cannot fix it.
        #expect(!UsageService.shouldSelfHealForTest(failures: ["a": .decryptFailed(.notV10)]))
        #expect(!UsageService.shouldSelfHealForTest(failures: ["a": .decryptFailed(.notBlockAligned)]))
        #expect(!UsageService.shouldSelfHealForTest(failures: ["a": .noTokenCache]))
    }

    @Test
    func aCleanlyDecryptedSiblingNeitherTriggersNorBlocksSelfHeal() {
        // `.signedOut` decrypted to valid JSON, so on its own it is no evidence of a rotated key.
        // But it must not *veto* recovery either, tempting as that is to spare a futile re-derive:
        // a profile signed out long ago keeps a cache written under the key of its day, so after a
        // rotation it still decrypts while every live profile's rewritten cache does not — and a
        // veto there would strand the whole fleet with no usage until relaunch.
        let rotated = TokenProviderError.decryptFailed(.decryptFailed)
        #expect(!UsageService.shouldSelfHealForTest(failures: ["a": .signedOut]))
        #expect(UsageService.shouldSelfHealForTest(failures: ["a": rotated, "b": .signedOut]))
    }
}

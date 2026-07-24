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
        // And the rejection is remembered, so the next tick doesn't re-ask for the name.
        let later = now.addingTimeInterval(6 * 3600)
        _ = await service.refresh(bindings: [binding("p")], now: later)
        #expect(http.profileCallCount == 1)
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
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
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
    func siblingLaunchersShareOneIdentityLookup() async {
        // The name belongs to the account, not the token, so two launchers on one login must not
        // each pay for it. They hold different tokens, so only an account-keyed lookup can hit.
        let http = ScriptedHTTP(usage: usageBody, accountUUID: "acct")
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(provider: StubProvider(results: [
            "p1": .success(token("p1", lastKnown: "acct")),
            "p2": .success(token("p2", lastKnown: "acct"))
        ]), http: http, history: history)
        _ = await service.refresh(bindings: [binding("p1"), binding("p2")], now: now)
        #expect(http.profileCallCount == 1)
        #expect(http.usageCallCount == 1)
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
        // Hours later, still parked — no second identity attempt, no usage attempt.
        let later = now.addingTimeInterval(6 * 3600)
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
            provider: StubProvider(results: ["p": .success(token("p", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)
        // A later *background* pass stays parked…
        let later = now.addingTimeInterval(6 * 3600)
        _ = await service.refresh(bindings: [binding("p")], now: later)
        #expect(http.usageCallCount == 1)
        // …an explicit Refresh tries again.
        _ = await service.refresh(bindings: [binding("p")], now: later, interactive: true)
        #expect(http.usageCallCount == 2)
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
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-A", lastKnown: "acct"))]),
            http: http,
            history: history
        )
        _ = await first.refresh(bindings: [binding("p")], now: now)
        #expect(http.usageCallCount == 1)
        // Same account, different elected token → different fingerprint, still inside the window.
        let second = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "TK-B", lastKnown: "acct"))]),
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
}

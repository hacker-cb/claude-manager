import Foundation
import Testing
@testable import ClaudeManagerCore

/// The finite terminal (401/403) park: how wide it is, when it doubles and when it must not,
/// that the background poll re-probes when it runs out, and that the legacy permanent
/// (`distantFuture`) rows older versions wrote read as already expired. The interactive early
/// exit lives with the other gates in `UsageServiceGateTests`.
extension UsageServiceTests {
    @Test
    func unauthorizedParksFinitelyAndRetriesAfterTheWindow() async {
        // `/profile` answers so the account is *named* and the park lives under the stable
        // account uuid — the scope a re-login lands back on. On a provisional account the new
        // token's fingerprint keys a different scope entirely, and the re-login half of this
        // test would pass with `clearsTerminal`'s re-login branch deleted.
        let http401 = ScriptedHTTP { url, _ in
            if url.path.hasSuffix(CoreConstants.usageAPIProfilePath) {
                return HTTPResponse(status: 200, body: ScriptedHTTP.profileBody("acct"))
            }
            return HTTPResponse(status: 401, body: Data())
        }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http401,
            history: history
        )
        let first = await service.refresh(bindings: [binding("p")], now: now)
        #expect(first.accounts.first?.state == .loginNeeded)
        #expect(http401.usageCallCount == 1)
        // Inside the park → no new call, and still honest about why.
        let inside = now.addingTimeInterval(UsageService.terminalBackoffSeconds / 2)
        let parked = await service.refresh(bindings: [binding("p")], now: inside)
        #expect(http401.usageCallCount == 1)
        #expect(parked.accounts.first?.state == .loginNeeded)
        // Past it, a plain background tick re-probes on its own — no Refresh, no re-login.
        let after = now.addingTimeInterval(UsageService.terminalBackoffSeconds + 60)
        _ = await service.refresh(bindings: [binding("p")], now: after)
        #expect(http401.usageCallCount == 2)
        // That scheduled probe 401'd too, so the window doubled: one first-width later is still
        // inside it.
        let insideSecond = after.addingTimeInterval(UsageService.terminalBackoffSeconds + 60)
        _ = await service.refresh(bindings: [binding("p")], now: insideSecond)
        #expect(http401.usageCallCount == 2)
        // A re-login (fingerprint change) retries immediately: same account, same scope, park
        // still standing — only the changed token lifts it on this background pass.
        let httpOK = ScriptedHTTP(usage: usageBody)
        let relogged = makeService(
            provider: StubProvider(results: ["p": .success(token("p", value: "NEW"))]),
            http: httpOK,
            history: history
        )
        let retried = await relogged.refresh(bindings: [binding("p")], now: insideSecond)
        #expect(httpOK.usageCallCount == 1)
        #expect(retried.accounts.first?.state == .fresh)
    }

    @Test
    func interactiveRetriesDoNotEscalateThePark() async {
        // A user with a stuck account does the human thing: presses Refresh, repeatedly. Every
        // press really retries (the documented early exit) and really gets rejected — but those
        // rejections measure the user's patience, not the login, so the window must keep its
        // width instead of doubling per press. Doubling here rode a 15-minute park to the 6-hour
        // cap inside a minute of clicking, leaving the user strictly worse off than doing nothing.
        let http401 = ScriptedHTTP { _, _ in HTTPResponse(status: 401, body: Data()) }
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http401,
            history: history
        )
        _ = await service.refresh(bindings: [binding("p")], now: now)
        #expect(http401.usageCallCount == 1)
        // Two Refresh presses inside the park, a minute apart — each retries…
        let press1 = now.addingTimeInterval(60)
        _ = await service.refresh(bindings: [binding("p")], now: press1, interactive: true)
        #expect(http401.usageCallCount == 2)
        let press2 = now.addingTimeInterval(120)
        _ = await service.refresh(bindings: [binding("p")], now: press2, interactive: true)
        #expect(http401.usageCallCount == 3)
        // …and the window stays one first-width from the last press: still parked just before
        // it runs out, probing again just after. A doubled (let alone re-doubled) window would
        // still be standing at the second probe.
        let width = UsageService.terminalBackoffSeconds
        _ = await service.refresh(bindings: [binding("p")], now: press2.addingTimeInterval(width - 31))
        #expect(http401.usageCallCount == 3)
        _ = await service.refresh(bindings: [binding("p")], now: press2.addingTimeInterval(width + 1))
        #expect(http401.usageCallCount == 4)
    }

    @Test
    func nextTerminalBackoffEscalatesOnlyScheduledProbesOfOneToken() {
        // Pure-function check of the widths; the service tests around it prove the wiring.
        let start = UsageService.terminalBackoffSeconds
        let cap = UsageService.maxTerminalBackoffSeconds
        #expect(UsageService.nextTerminalBackoff(after: nil, fingerprint: "fp", now: now) == start)
        // A scheduled probe — the previous window ran out — doubles…
        let ranOut = ThrottleState(
            lastAttemptAt: now.addingTimeInterval(-start - 100),
            backoffUntil: now.addingTimeInterval(-100),
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: ranOut, fingerprint: "fp", now: now) == start * 2)
        // …up to its own ceiling, which outgrows the ordinary error cap on purpose.
        let wide = ThrottleState(
            lastAttemptAt: now.addingTimeInterval(-cap - 100),
            backoffUntil: now.addingTimeInterval(-100),
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: wide, fingerprint: "fp", now: now) == cap)
        // An early retry — the window still running — keeps the width instead of doubling.
        let running = ThrottleState(
            lastAttemptAt: now.addingTimeInterval(-60),
            backoffUntil: now.addingTimeInterval(start - 60),
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: running, fingerprint: "fp", now: now) == start)
        // A different token starts fresh, however wide the old token's window had grown —
        // a re-login must not inherit the dead login's multi-hour sentence.
        #expect(UsageService.nextTerminalBackoff(after: wide, fingerprint: "other", now: now) == start)
        // A non-terminal window and the legacy permanent park both start fresh too.
        let offline = ThrottleState(
            lastAttemptAt: now.addingTimeInterval(-100),
            backoffUntil: now.addingTimeInterval(3600),
            backoffReason: .offline,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: offline, fingerprint: "fp", now: now) == start)
        let legacy = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: .distantFuture,
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: legacy, fingerprint: "fp", now: now) == start)
    }

    @Test
    func legacyPermanentParkReadsAsExpiredAndRetries() async throws {
        // Older versions wrote terminal parks as `distantFuture`, and rows like that survive in
        // users' databases. A parked account is never called, so nothing ever rewrites its row —
        // under the finite-park rule those rows must read as already expired, or exactly the
        // accounts this change is for stay dead until a manual Refresh.
        let http = ScriptedHTTP(usage: usageBody)
        let history = UsageHistoryStore(path: ":memory:")
        let service = makeService(
            provider: StubProvider(results: ["p": .success(token("p"))]),
            http: http,
            history: history
        )
        // Learn the scopes a real pass uses (the account uuid and the token fingerprint) — and
        // *require* them: falling back to a made-up scope would plant the legacy rows where the
        // service never looks, and the retry assertion below would then pass without exercising
        // the legacy-park rule at all.
        let seeded = await service.refresh(bindings: [binding("p")], now: now)
        let uuid = try #require(seeded.accounts.first?.identity.uuid)
        let fingerprint = token("p").fingerprint
        // …then plant the legacy rows exactly as an older build left them.
        let legacy = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: .distantFuture,
            backoffReason: .terminal,
            tokenFingerprint: fingerprint
        )
        await history.setThrottle(legacy, scope: UsageService.usageScope(uuid))
        await history.setThrottle(legacy, scope: UsageService.identityScope(fingerprint))
        // A plain background tick past the floor retries — no Refresh, no re-login.
        let result = await service.refresh(bindings: [binding("p")], now: now.addingTimeInterval(120))
        #expect(http.usageCallCount == 2)
        #expect(result.accounts.first?.state == .fresh)
    }
}

import Foundation
import Testing
@testable import ClaudeManagerCore

/// The finite terminal (401/403) park: how wide it is, that the background poll re-probes when
/// it runs out, and that the legacy permanent (`distantFuture`) rows older versions wrote read
/// as already expired. The early exits — a re-login, an explicit Refresh — live with the other
/// gates in `UsageServiceGateTests`.
extension UsageServiceTests {
    @Test
    func unauthorizedParksFinitelyAndRetriesAfterTheWindow() async {
        let history = UsageHistoryStore(path: ":memory:")
        let http401 = ScriptedHTTP { _, _ in HTTPResponse(status: 401, body: Data()) }
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
        // That probe 401'd too, so the window doubled: one first-width later is still inside it.
        let insideSecond = after.addingTimeInterval(UsageService.terminalBackoffSeconds + 60)
        _ = await service.refresh(bindings: [binding("p")], now: insideSecond)
        #expect(http401.usageCallCount == 2)
        // A re-login (fingerprint change) still retries immediately, park or no park.
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
    func nextTerminalBackoffDoublesToItsOwnCap() {
        // Pure-function check of the widths; the service tests around it prove the wiring.
        #expect(UsageService.nextTerminalBackoff(after: nil) == UsageService.terminalBackoffSeconds)
        // A previous finite terminal window doubles…
        let prev = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: now.addingTimeInterval(UsageService.terminalBackoffSeconds),
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: prev) == UsageService.terminalBackoffSeconds * 2)
        // …up to its own ceiling, which outgrows the ordinary error cap on purpose.
        let wide = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: now.addingTimeInterval(UsageService.maxTerminalBackoffSeconds),
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: wide) == UsageService.maxTerminalBackoffSeconds)
        // A non-terminal window and the legacy permanent park both start fresh.
        let offline = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: now.addingTimeInterval(3600),
            backoffReason: .offline,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: offline) == UsageService.terminalBackoffSeconds)
        let legacy = ThrottleState(
            lastAttemptAt: now,
            backoffUntil: .distantFuture,
            backoffReason: .terminal,
            tokenFingerprint: "fp"
        )
        #expect(UsageService.nextTerminalBackoff(after: legacy) == UsageService.terminalBackoffSeconds)
    }

    @Test
    func legacyPermanentParkReadsAsExpiredAndRetries() async {
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
        // Learn the scopes a real pass uses (the account uuid and the token fingerprint)…
        let seeded = await service.refresh(bindings: [binding("p")], now: now)
        let uuid = seeded.accounts.first?.identity.uuid ?? ""
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

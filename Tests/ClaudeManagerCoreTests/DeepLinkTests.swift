import Foundation
import Testing
@testable import ClaudeManagerCore

struct DeepLinkURLTests {
    @Test
    func isClaudeURLAcceptsOnlyClaudeScheme() {
        #expect(DeepLink.isClaudeURL("claude://oauth/callback?code=abc"))
        #expect(DeepLink.isClaudeURL("CLAUDE://x")) // scheme is case-insensitive
        #expect(!DeepLink.isClaudeURL("https://anthropic.com"))
        #expect(!DeepLink.isClaudeURL("claudex://y"))
        #expect(!DeepLink.isClaudeURL("not a url"))
        #expect(!DeepLink.isClaudeURL(""))
        // Bare opaque form (no authority) is not the deep-link shape → rejected.
        #expect(!DeepLink.isClaudeURL("claude:foo"))
        // Hierarchical but authority-less forms are rejected too (documented contract).
        #expect(!DeepLink.isClaudeURL("claude://"))
        #expect(!DeepLink.isClaudeURL("claude:///path"))
    }
}

struct ForwardingTests {
    let fm = FileManager.default

    @Test
    func forwardsClaudeURLToLauncherWithArgs() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile

        let url = "claude://oauth/callback?code=abc123"
        try env.store.openForwarding(profile, url: url)
        let call = try #require(env.runner.invocations(of: CoreConstants.openPath).last)
        #expect(call.arguments == ["-n", profile.appPath, "--args", url])
    }

    @Test
    func rejectsNonClaudeURL() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile

        #expect(throws: ClaudeManagerError.self) {
            try env.store.openForwarding(profile, url: "https://evil.example/steal")
        }
        // Nothing was launched for the rejected URL.
        #expect(env.runner.invocations(of: CoreConstants.openPath).isEmpty)
    }

    @Test
    func forwardsToDefaultAccountViaRealApp() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let url = "claude://magic-link#token"
        try env.store.openRealForwarding(url: url)
        let call = try #require(env.runner.invocations(of: CoreConstants.openPath).last)
        #expect(call.arguments == ["-n", env.real.appURL.path, "--args", url])
    }

    @Test
    func realForwardingRejectsNonClaudeURL() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.openRealForwarding(url: "ftp://nope")
        }
    }
}

/// A stub OS-observer registrar: captures the `onChange` callback so a test can fire the
/// "database changed" event on demand, and records cancellation.
final class StubObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?
    private(set) var cancelled = false
    private(set) var observedName: String?

    var registrar: LaunchServicesHandlerGuard.ObserverRegistrar {
        { [self] name, handler in
            lock.lock(); observedName = name; onChange = handler; lock.unlock()
            return { [self] in lock.lock(); cancelled = true; onChange = nil; lock.unlock() }
        }
    }

    func fire() {
        lock.lock(); let handler = onChange; lock.unlock()
        handler?()
    }
}

/// A mutable holder for the "current handler" the guard sees, so a test can flip who
/// owns the scheme between events.
final class HandlerState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String?) {
        value = initial
    }

    var current: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

struct LaunchServicesHandlerGuardTests {
    let ourID = "io.github.hacker-cb.claude-manager"

    @Test
    func reassertsOnlyWhenWeDoNotOwnTheScheme() {
        let state = HandlerState("com.anthropic.claudefordesktop") // Claude grabbed it
        let reassertCount = Counter()
        let guardService = LaunchServicesHandlerGuard(
            ourBundleID: ourID,
            currentHandler: { state.current },
            reassert: { state.current = "io.github.hacker-cb.claude-manager"; reassertCount.bump() },
            registrar: StubObserver().registrar
        )
        #expect(guardService.reassertIfNeeded()) // someone else owns it → re-assert
        #expect(reassertCount.value == 1)
        // Now we own it — the self-guard makes a second call a no-op (no loop).
        #expect(!guardService.reassertIfNeeded())
        #expect(reassertCount.value == 1)
    }

    @Test
    func startTakesHandlerAndReassertsOnEachDBChange() {
        let state = HandlerState(nil) // nobody owns it yet
        let reassertCount = Counter()
        let observer = StubObserver()
        let guardService = LaunchServicesHandlerGuard(
            ourBundleID: ourID,
            currentHandler: { state.current },
            reassert: { state.current = "io.github.hacker-cb.claude-manager"; reassertCount.bump() },
            registrar: observer.registrar
        )
        guardService.start()
        #expect(reassertCount.value == 1) // took the handler immediately
        #expect(observer.observedName == LaunchServicesHandlerGuard.databaseChangedNotificationName())

        // A DB change that doesn't dislodge us → no re-assert (self-guard).
        observer.fire()
        #expect(reassertCount.value == 1)

        // Claude grabs it → the next DB change makes us take it back.
        state.current = "com.anthropic.claudefordesktop"
        observer.fire()
        #expect(reassertCount.value == 2)

        guardService.stop()
        #expect(observer.cancelled)
        // After stop, further events are ignored.
        state.current = "com.anthropic.claudefordesktop"
        observer.fire()
        #expect(reassertCount.value == 2)
    }

    @Test
    func startIsIdempotent() {
        let observer = StubObserver()
        let guardService = LaunchServicesHandlerGuard(
            ourBundleID: ourID,
            currentHandler: { "io.github.hacker-cb.claude-manager" }, // we already own it
            reassert: {},
            registrar: observer.registrar
        )
        guardService.start()
        guardService.start() // second start must not re-register
        guardService.stop()
        #expect(observer.cancelled)
    }
}

/// A tiny thread-safe counter for the guard tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func bump() {
        lock.lock(); value += 1; lock.unlock()
    }
}

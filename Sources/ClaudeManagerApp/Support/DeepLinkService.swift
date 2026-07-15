import AppKit
import ClaudeManagerCore

/// App-layer wiring for the `claude://` broker: registers Claude Manager as the default
/// handler, holds it via a `LaunchServicesHandlerGuard` (event-driven re-assert, no
/// polling), and restores Claude on disable.
///
/// Core owns the *decision* logic (`LaunchServicesHandlerGuard`); this type supplies the
/// three OS-specific closures it can't: querying the current handler (`NSWorkspace`),
/// re-asserting ourselves, and observing the LaunchServices "database changed" Darwin
/// notification (`CFNotificationCenter`). Runs on the main actor.
@MainActor
final class DeepLinkService {
    private let ourBundleID: String
    private let ourBundleURL: URL
    private var handlerGuard: LaunchServicesHandlerGuard?

    init(
        ourBundleID: String = Bundle.main.bundleIdentifier ?? "io.github.hacker-cb.claude-manager",
        ourBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.ourBundleID = ourBundleID
        self.ourBundleURL = ourBundleURL
    }

    /// The bundle id currently registered as the `claude://` default handler, if any.
    func currentClaudeHandlerBundleID() -> String? {
        guard let probe = URL(string: "\(CoreConstants.claudeURLScheme)://"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Register Claude Manager as the default `claude://` handler and start holding it.
    /// Idempotent. Call when the broker is enabled.
    func startHolding() {
        let register = makeReassert(to: ourBundleURL)
        let handlerGuard = handlerGuard ?? LaunchServicesHandlerGuard(
            ourBundleID: ourBundleID,
            currentHandler: { [weak self] in self?.currentHandlerBundleIDSendable() },
            reassert: register,
            registrar: Self.darwinRegistrar
        )
        self.handlerGuard = handlerGuard
        handlerGuard.start()
    }

    /// Stop holding the handler and hand `claude://` back to the real Claude app, so the
    /// default account regains deep links. Call when the broker is disabled.
    func stopHoldingAndRestore(to realClaude: RealClaude?) {
        handlerGuard?.stop()
        handlerGuard = nil
        if let realClaude {
            makeReassert(to: realClaude.appURL)()
        }
    }

    /// Re-assert now if we're meant to be holding the handler — e.g. from
    /// `didBecomeActive`, a cheap guaranteed re-check on top of the Darwin observer.
    func reassertIfNeeded() {
        handlerGuard?.reassertIfNeeded()
    }

    // MARK: - OS closures

    /// A `@Sendable` snapshot of the current handler for the guard's closure. The lookup
    /// is main-actor work; we hop on via `MainActor.assumeIsolated` since the guard only
    /// ever invokes it on the main queue.
    private nonisolated func currentHandlerBundleIDSendable() -> String? {
        MainActor.assumeIsolated { currentClaudeHandlerBundleID() }
    }

    private func makeReassert(to appURL: URL) -> @Sendable () -> Void {
        { @Sendable in
            MainActor.assumeIsolated {
                NSWorkspace.shared.setDefaultApplication(
                    at: appURL,
                    toOpenURLsWithScheme: CoreConstants.claudeURLScheme
                )
            }
        }
    }

    /// A `CFNotificationCenter` Darwin-notification observer registrar (pure CoreFoundation,
    /// no bridging header). Delivers on the thread's run loop — the main run loop here —
    /// matching the guard's main-queue expectation. Returns a cancel closure.
    private static let darwinRegistrar: LaunchServicesHandlerGuard.ObserverRegistrar = { name, onChange in
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let box = ObserverBox(onChange)
        let context = Unmanaged.passRetained(box).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue().fire()
        }
        CFNotificationCenterAddObserver(
            center, context, callback, name as CFString, nil, .deliverImmediately
        )
        // The cancel closure must be @Sendable, but `center`/`context` are non-Sendable
        // CoreFoundation values; box the cancellation so the returned closure captures
        // only a Sendable holder (the Darwin center is a global, re-fetched on cancel).
        let cancellation = ObserverCancellation(context: context, name: name)
        return { cancellation.cancel() }
    }
}

/// Retains a `@Sendable` callback so it can ride through a `CFNotificationCenter`
/// C-callback's opaque context pointer.
private final class ObserverBox: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func fire() {
        onChange()
    }
}

/// A Sendable holder for the pointer + name needed to unregister a Darwin observer, so
/// the guard's `@Sendable` cancel closure captures only this (used on the main queue).
private final class ObserverCancellation: @unchecked Sendable {
    private let context: UnsafeMutableRawPointer
    private let name: String
    init(context: UnsafeMutableRawPointer, name: String) {
        self.context = context
        self.name = name
    }

    func cancel() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), context,
            CFNotificationName(name as CFString), nil
        )
        Unmanaged<ObserverBox>.fromOpaque(context).release()
    }
}

import Foundation

/// Keeps Claude Manager the default handler for `claude://` by **re-asserting** whenever
/// the LaunchServices default-handler database changes — event-driven, no polling.
///
/// Claude calls `setAsDefaultProtocolClient("claude")` on every launch, re-grabbing the
/// scheme. The primary defense is the `disableDeepLinkRegistration` overlay; this guard
/// is the fallback for any instance that still registers. It observes the Darwin
/// notification `user.uid.<uid>.com.apple.LaunchServices.database`, which fires shortly
/// *after* the handler actually changes — so a re-assert in response deterministically
/// lands last. Changing the default handler for a *custom* scheme raises no user-consent
/// prompt.
///
/// The OS-specific pieces — querying the current handler, re-asserting ourselves, and
/// registering the Darwin observer — are injected as closures, so the decision logic and
/// lifecycle are unit-testable and Core stays AppKit-free. The self-guard *is*
/// ``reassertIfNeeded``: after a re-assert the handler is already us, so the DB-change our
/// own write triggers finds nothing to do — no feedback loop.
///
/// All methods run on the main queue; `@unchecked Sendable` reflects that single-threaded
/// use, not lock-freedom.
public final class LaunchServicesHandlerGuard: @unchecked Sendable {
    /// Returns the bundle id currently registered as the `claude://` default handler.
    public typealias HandlerQuery = @Sendable () -> String?
    /// Re-registers Claude Manager as the `claude://` default handler.
    public typealias ReassertAction = @Sendable () -> Void
    /// Registers an OS observer that calls `onChange` whenever the LaunchServices
    /// default-handler database changes, and returns a cancel closure. The App supplies a
    /// Darwin-notification-backed implementation; tests supply a stub that fires on demand.
    public typealias ObserverRegistrar =
        @Sendable (_ notificationName: String, _ onChange: @escaping @Sendable () -> Void)
            -> (@Sendable () -> Void)

    private let ourBundleID: String
    private let currentHandler: HandlerQuery
    private let reassert: ReassertAction
    private let registrar: ObserverRegistrar
    private let notificationName: String

    private var cancelObserver: (@Sendable () -> Void)?

    public init(
        ourBundleID: String,
        notificationName: String = LaunchServicesHandlerGuard.databaseChangedNotificationName(),
        currentHandler: @escaping HandlerQuery,
        reassert: @escaping ReassertAction,
        registrar: @escaping ObserverRegistrar
    ) {
        self.ourBundleID = ourBundleID
        self.notificationName = notificationName
        self.currentHandler = currentHandler
        self.reassert = reassert
        self.registrar = registrar
    }

    /// The per-user LaunchServices "database changed" Darwin notification name.
    public static func databaseChangedNotificationName(uid: uid_t = getuid()) -> String {
        "user.uid.\(uid).com.apple.LaunchServices.database"
    }

    /// Re-assert ourselves as the `claude://` handler iff we don't already own it.
    /// Returns whether it re-asserted. This is the self-guard: our own re-assert makes
    /// the handler us, so the resulting DB-change re-entry finds nothing to do.
    @discardableResult
    public func reassertIfNeeded() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard currentHandler() != ourBundleID else { return false }
        reassert()
        return true
    }

    /// Take the handler now, then observe DB changes and re-assert on each. Idempotent.
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard cancelObserver == nil else { return }
        reassertIfNeeded()
        cancelObserver = registrar(notificationName) { [weak self] in
            self?.reassertIfNeeded()
        }
    }

    /// Stop observing. Idempotent.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelObserver?()
        cancelObserver = nil
    }

    deinit { cancelObserver?() }
}

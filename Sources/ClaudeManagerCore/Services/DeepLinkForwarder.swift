import Foundation

/// How delivering a `claude://` link to a specific instance failed. Owned by core (rather
/// than the app-only Apple-event primitive) so the forwarder's outcome — and its tests —
/// never depend on the OS/AppKit layer. The app's `DeepLinkDelivery.send` throws these
/// directly, so there is no parallel mirror to keep in sync.
public enum DeepLinkDeliveryFailure: Error, Equatable, Sendable {
    /// The user hasn't granted (or has denied) Automation control of Claude.
    case notPermitted
    /// The target process is gone (quit between the pid probe and the send).
    case targetGone
    /// Any other Apple-event failure (`OSStatus`).
    case sendFailed(code: Int)
}

/// The pure orchestration behind forwarding one `claude://` link to one account: the
/// running-vs-cold branch, the bounded pid poll after a cold launch, and mapping the raw
/// launch/deliver results into a single `Outcome` the app turns into user-facing state.
///
/// Every real effect is injected, so the whole decision tree runs instantly and
/// deterministically in headless `swift test` with fakes — the actual OS-coupled bits
/// (`open -n`, the GURL Apple event, the `pgrep`/`ps` probe) stay in the thin app shell.
/// The forwarder itself is a `Sendable` value with no mutable state; it is built per target
/// and can forward several URLs.
///
/// **Serialization note.** The `launch`/`release` pair models a scoped launch slot: for the
/// untouched default account the app must not `open -n` two instances on one user-data-dir
/// (no `shlock` guards it — it would corrupt the LevelDB). The forwarder calls `launch`
/// **only on the cold path** (a running instance is delivered to directly, never launched),
/// and calls `release` exactly once **after** the poll + deliver of a launch that reported
/// `.started` — so the app's `isOpeningReal` token is held across the whole cold span and
/// never across a delivery to an already-running instance. A `.alreadyInFlight` launch was
/// started by someone else, so the forwarder polls without ever releasing a slot it doesn't
/// own; a `.failed` launch is released by the app at the point it failed.
public struct DeepLinkForwarder: Sendable {
    /// The result of asking the app to cold-launch the target.
    public enum LaunchResult: Sendable, Equatable {
        /// This call started the instance and holds the launch slot; the forwarder will
        /// `release()` after the poll + deliver.
        case started
        /// Another launch of the same target is already in flight; poll for it, don't
        /// launch again, and don't release (this call never acquired the slot).
        case alreadyInFlight
        /// The launch didn't start; the app already surfaced the reason, so the forwarder
        /// short-circuits without polling or delivering.
        case failed
    }

    /// The single value the app maps to `currentError` (no UI ever enters core).
    public enum Outcome: Sendable, Equatable {
        /// Delivered — Claude routes it to the right window itself.
        case delivered
        /// The cold launch didn't start; the app already surfaced the reason (don't stack a
        /// second notice on top).
        case launchFailed
        /// The instance never became reachable within the poll budget.
        case neverAppeared
        /// The GURL hand-off itself failed.
        case deliveryFailed(DeepLinkDeliveryFailure)
    }

    /// Default cold-launch pid-poll budget: how many probes, and the gap between them, to
    /// wait for a freshly `open -n`'d default-account instance to become visible to `ps`.
    /// Exposed and shared so the toolbar `openReal` launch and this forwarder's cold path
    /// hold the identical window before giving up (#38). ~40 × 300 ms ≈ 12 s.
    public static let coldLaunchPollAttempts = 40
    /// Delay between the cold-launch pid probes (see `coldLaunchPollAttempts`).
    public static let coldLaunchPollInterval: Duration = .milliseconds(300)

    /// Number of pid probes after a cold launch before giving up.
    public let pollAttempts: Int
    /// Delay between pid probes.
    public let pollInterval: Duration
    /// Settle delay once the pid appears, before delivering — Claude stashes a cold-start URL
    /// that arrives before its window is ready, so this need only be approximate.
    public let settle: Duration

    /// Probe for the target's running pid (`nil` == not running / not yet up).
    private let probePID: @Sendable () async -> Int32?
    /// Cold-launch the target. Called only when `probePID` first returned `nil`.
    private let launch: @Sendable () async -> LaunchResult
    /// Release the launch slot acquired by a `.started` launch. Called once, after the cold
    /// path's poll + deliver. Never called for a running / `.alreadyInFlight` / `.failed`
    /// path. `async` because it hops to the app's main actor to clear `isOpeningReal` — which
    /// is also why `forward` calls it explicitly rather than from a `defer` (Swift forbids
    /// `await` in `defer`); the cold `.started` path is straight-line and non-throwing, so the
    /// call is always reached.
    private let release: @Sendable () async -> Void
    /// Deliver the URL to a live pid via the GURL Apple event; `nil` == delivered.
    private let deliver: @Sendable (URL, Int32) async -> DeepLinkDeliveryFailure?
    /// Sleep (injected so tests pass a no-op and run instantly).
    private let sleep: @Sendable (Duration) async -> Void
    /// Orchestration-level paper trail (branch chosen, launch result, give-up). Injected so
    /// core stays free of `OSLog`; the app supplies a target-scoped `Log.deepLink` sink.
    private let log: @Sendable (String) -> Void

    public init(
        pollAttempts: Int = DeepLinkForwarder.coldLaunchPollAttempts,
        pollInterval: Duration = DeepLinkForwarder.coldLaunchPollInterval,
        settle: Duration = .milliseconds(700),
        probePID: @escaping @Sendable () async -> Int32?,
        launch: @escaping @Sendable () async -> LaunchResult,
        release: @escaping @Sendable () async -> Void = {},
        deliver: @escaping @Sendable (URL, Int32) async -> DeepLinkDeliveryFailure?,
        sleep: @escaping @Sendable (Duration) async -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.pollAttempts = pollAttempts
        self.pollInterval = pollInterval
        self.settle = settle
        self.probePID = probePID
        self.launch = launch
        self.release = release
        self.deliver = deliver
        self.sleep = sleep
        self.log = log
    }

    /// Forward `url` to the target. Running → deliver straight to its pid. Not running →
    /// cold-launch, poll (bounded) for the pid, settle, then deliver.
    public func forward(_ url: URL) async -> Outcome {
        if let pid = await probePID() {
            log("running (pid \(pid)) → GURL")
            return await outcome(of: deliver(url, pid))
        }
        let result = await launch()
        log("not running → launch \(result)")
        switch result {
        case .failed:
            return .launchFailed
        case .alreadyInFlight:
            // Someone else owns the slot — poll + deliver, but never release it.
            return await pollThenDeliver(url)
        case .started:
            let outcome = await pollThenDeliver(url)
            await release()
            return outcome
        }
    }

    /// Poll for the just-launched instance's pid (bounded), then settle and deliver.
    private func pollThenDeliver(_ url: URL) async -> Outcome {
        guard let pid = await AsyncPoll.firstNonNil(
            attempts: pollAttempts, interval: pollInterval, sleep: sleep, probe: probePID
        ) else {
            log("instance never came up after \(pollAttempts) probes — not delivered")
            return .neverAppeared
        }
        await sleep(settle)
        return await outcome(of: deliver(url, pid))
    }

    private func outcome(of failure: DeepLinkDeliveryFailure?) -> Outcome {
        failure.map(Outcome.deliveryFailed) ?? .delivered
    }
}

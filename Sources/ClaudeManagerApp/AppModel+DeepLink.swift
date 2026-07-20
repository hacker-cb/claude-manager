import AppKit
import ClaudeManagerCore

/// Where a `claude://` deep link should be routed.
enum DeepLinkTarget: Identifiable, Hashable {
    case profile(Profile)
    case defaultAccount

    var id: String {
        switch self {
        case let .profile(profile): profile.id
        case .defaultAccount: "__default__"
        }
    }

    var displayName: String {
        switch self {
        case let .profile(profile): profile.displayName
        case .defaultAccount: "Default account"
        }
    }
}

/// The `claude://` broker: intake, the account picker, forwarding, and applying /
/// restoring the handler when the feature is toggled. The URL carries no account
/// identity, so routing is a user choice — hence the picker.
extension AppModel {
    /// Handle inbound deep links from `AppDelegate`. Only `claude://` URLs are routed.
    /// Every URL in the batch is queued (not just the first) and shown a picker one at a
    /// time. If the broker is off but a link still reached us (we declare the scheme),
    /// hand each straight to the default account rather than brokering a disabled feature.
    func handleDeepLinks(_ urls: [URL]) {
        let claudeURLs = urls.filter { DeepLink.isClaudeURL($0.absoluteString) }
        let rejected = urls.filter { !DeepLink.isClaudeURL($0.absoluteString) }
        if !rejected.isEmpty {
            let rendered = rejected.map(\.logDescription).joined(separator: ", ")
            Log.deepLink
                .error(
                    "rejected \(rejected.count, privacy: .public) URL(s) failing isClaudeURL (need claude://<host>): [\(rendered, privacy: .public)]"
                )
        }
        let summary = "\(urls.count) in, \(claudeURLs.count) accepted, broker=\(deepLinkBrokerEnabled)"
        Log.deepLink.info("handleDeepLinks: \(summary, privacy: .public)")
        guard !claudeURLs.isEmpty else { return }
        guard deepLinkBrokerEnabled else {
            Log.deepLink
                .info(
                    "broker OFF branch: forwarding \(claudeURLs.count, privacy: .public) link(s) to the default account"
                )
            // Broker off, but we still declare the scheme, so a link can reach us — hand every
            // link to the default account. Sequentially: the first cold-launches it (if not
            // running) and the rest deliver by GURL to that now-live instance, so a batch no
            // longer loses all but the first the way argv delivery did.
            Task {
                for url in claudeURLs {
                    await forwardToDefaultAccount(url: url)
                }
                await refresh()
            }
            return
        }
        pendingDeepLinkQueue.append(contentsOf: claudeURLs)
        let queued = "\(claudeURLs.count) link(s), queue now \(pendingDeepLinkQueue.count)"
        Log.deepLink.info("queued for the picker: \(queued, privacy: .public)")
        presentNextDeepLinkIfIdle()
    }

    /// Point the AppKit delegate's deep-link sink at this model, retrying until SwiftUI has
    /// constructed our `@NSApplicationDelegateAdaptor` and published it via `AppDelegate.shared`.
    ///
    /// SwiftUI keeps its *own* object as `NSApp.delegate` and only forwards callbacks to the
    /// adaptor's `AppDelegate`, so `NSApp.delegate as? AppDelegate` is always nil — the
    /// original wiring assigned into that nil, so every inbound `claude://` link buffered on
    /// the (never-wired) delegate and was dropped (window opened, but no picker and no
    /// forward). We reach the real instance through `AppDelegate.shared` (set in its `init`)
    /// instead, retrying on the main queue until the adaptor has created it. This works for
    /// every launch mode, including window-less logins where `RootView.task` never fires.
    ///
    /// Each retry is spaced by `retryInterval` (`asyncAfter`, not a tight `async` re-enqueue)
    /// so the bounded budget spans *real time* — otherwise 200 back-to-back main-queue blocks
    /// could drain in a single runloop servicing and exhaust before the adaptor constructs the
    /// delegate. In practice attempt 0 already succeeds (the delegate's `init` runs before the
    /// queue is serviced); the interval only matters for a pathologically late construction.
    func wireDeepLinkHandler(attempt: Int = 0) {
        guard let delegate = AppDelegate.shared else {
            guard attempt < 200 else {
                Log.deepLink
                    .error(
                        "deepLinkHandler never wired: AppDelegate.shared nil after \(attempt, privacy: .public) attempts"
                    )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wireRetryInterval) { [weak self] in
                self?.wireDeepLinkHandler(attempt: attempt + 1)
            }
            return
        }
        delegate.deepLinkHandler = { [weak self] urls in self?.handleDeepLinks(urls) }
        Log.deepLink.info("deepLinkHandler wired after \(attempt, privacy: .public) retry(ies)")
    }

    /// Delay between `wireDeepLinkHandler` retries. 200 attempts × 50 ms bounds the wait at
    /// ~10 s — ample for the adaptor to construct the delegate, without a busy main-queue spin.
    private static let wireRetryInterval: TimeInterval = 0.05

    /// Idempotent launch work: start monitoring, paint the list, and apply the deep-link
    /// broker (grab the `claude://` handler). Runs once — from `init` on every launch
    /// (window or not) and, as a fallback, from `RootView.task`.
    func performLaunchTasks() async {
        guard !didPerformLaunch else {
            Log.deepLink.info("performLaunchTasks: already ran, skipping")
            return
        }
        didPerformLaunch = true
        Log.deepLink.info("performLaunchTasks: monitoring + refresh + broker apply")
        startMonitoring()
        await refresh()
        await applyDeepLinkBroker()
    }

    /// Serialize broker applies so a rapid toggle can't race two read-modify-write passes
    /// over the same default-account overlay files — each apply awaits the previous. Called
    /// from the `deepLinkBrokerEnabled` didSet.
    func scheduleBrokerApply() {
        let previous = brokerApplyTask
        brokerApplyTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyDeepLinkBroker()
        }
    }

    /// Register / restore the handler and reconcile the overlays for the current broker
    /// setting. The single entry point, called from the Settings toggle and at startup.
    ///
    /// The store reconciles the clones *and* the default account when Claude is located.
    /// When it isn't (`realClaude == nil`, so `perform` bails), the default account's
    /// overlay — the safety-critical restore — is still reconciled directly, because it
    /// needs only the default user-data path, not the real app. Exactly one path ever
    /// writes the default account, so the two never race.
    func applyDeepLinkBroker() async {
        let storeReconciled = await perform { store in store.reconcileAllManagedConfigs() } != nil
        if !storeReconciled {
            await reconcileDefaultAccountOverlayDirectly()
        }
        if deepLinkBrokerEnabled {
            Log.broker
                .info(
                    "applyDeepLinkBroker: storeReconciled=\(storeReconciled, privacy: .public) → startHolding"
                )
            deepLinkService.startHolding()
        } else {
            Log.broker
                .info(
                    "applyDeepLinkBroker: storeReconciled=\(storeReconciled, privacy: .public) → stopHoldingAndRestore"
                )
            deepLinkService.stopHoldingAndRestore(to: realClaude)
        }
    }

    /// Clean any CM-written overlay off the default account (its handler is held by the
    /// guard, never a written key), independently of `realClaude` via a plain
    /// `ManagedConfigWriter`. Used only as the fallback when the store is unavailable, so
    /// it never races the store's own default-account cleanup. Off-main (file IO).
    private func reconcileDefaultAccountOverlayDirectly() async {
        await Task.detached {
            try? ManagedConfigWriter().reconcilePreservingUntouched(
                .defaultAccount, userDataPath: ProfileStoreConfiguration.systemDefaultAccountUserDataPath
            )
        }.value
    }

    // MARK: - Picker + forwarding

    /// Present the next queued link's picker when nothing is already on screen. Reserve the
    /// presenter *before* spawning the task: `presentPicker` `await`s a refresh before the
    /// window (the other idle signal) exists, so without the reservation two links arriving
    /// close together would both pass the guard and present overlapping pickers.
    private func presentNextDeepLinkIfIdle() {
        guard !deepLinkPresenter.isPresenting, !pendingDeepLinkQueue.isEmpty else {
            let state = "presenting=\(deepLinkPresenter.isPresenting), queue=\(pendingDeepLinkQueue.count)"
            Log.deepLink.info("presentNextDeepLinkIfIdle: skipping (\(state, privacy: .public))")
            return
        }
        deepLinkPresenter.reserve()
        let url = pendingDeepLinkQueue.removeFirst()
        Log.deepLink
            .info(
                "presentNextDeepLinkIfIdle: reserving + presenting picker for \(url.logDescription, privacy: .public)"
            )
        Task { await presentPicker(for: url) }
    }

    private func presentPicker(for url: URL) async {
        // Always refresh so a since-deleted profile is never offered as a target.
        await refresh()
        // Claude vanished after the broker grabbed the handler — every target (default +
        // clones) would dead-end in "Real Claude.app was not found", so don't offer a picker
        // at all. Drain the queue, surface the reason once, and release the reservation so the
        // presenter doesn't stall. Mirrors `accounts`, which also hides the default when nil.
        guard realClaude != nil else {
            let reason = locateError ?? "not found"
            Log.deepLink
                .error(
                    "presentPicker: realClaude is nil — draining queue, no picker (\(reason, privacy: .public))"
                )
            currentError = AppError(message: locateError ?? "Real Claude.app was not found.")
            pendingDeepLinkQueue.removeAll()
            deepLinkPresenter.cancelReservation()
            return
        }
        // Default account first, matching the sidebar and menu-bar ordering.
        let targets: [DeepLinkTarget] = [.defaultAccount] + profiles.map { .profile($0.profile) }
        Log.deepLink
            .info(
                "presentPicker: showing picker with \(targets.count, privacy: .public) target(s) for \(url.logDescription, privacy: .public)"
            )
        deepLinkPresenter.present(url: url, targets: targets) { [weak self] target in
            Task { await self?.forwardDeepLink(url, to: target) }
        } onDismiss: { [weak self] in
            self?.presentNextDeepLinkIfIdle()
        }
    }

    private func forwardDeepLink(_ url: URL, to target: DeepLinkTarget) async {
        switch target {
        case let .profile(profile):
            await forwardToProfile(profile, url: url)
        case .defaultAccount:
            await forwardToDefaultAccount(url: url)
        }
        await refresh()
    }

    private func forwardToProfile(_ profile: Profile, url: URL) async {
        guard !launchBlockedByStagedApply() else {
            Log.deepLink
                .error("forwardToProfile(\(profile.displayName, privacy: .public)): blocked by staged apply")
            return
        }
        // Clones are `shlock`-guarded, so a not-running clone is safe to just cold-launch —
        // no duplicate-instance serialization is needed (hence the default no-op `release`).
        let name = profile.displayName
        let forwarder = DeepLinkForwarder(
            probePID: { [weak self] in await self?.pid(for: profile) },
            launch: { [weak self] in
                guard let self else { return .failed }
                return await perform { try $0.open(profile) } != nil ? .started : .failed
            },
            deliver: { [weak self] url, pid in
                guard let self else { return .targetGone }
                return await sendGURL(url, toPID: pid)
            },
            sleep: { try? await Task.sleep(for: $0) },
            log: { Log.deepLink.info("forwardToProfile(\(name, privacy: .public)): \($0, privacy: .public)") }
        )
        await applyOutcome(forwarder.forward(url), targetName: name)
    }

    /// Forward to the default account (the untouched real app). Running → GURL to its pid;
    /// not running → cold-launch, then deliver once it's up. `acquireDefaultLaunchSlot`
    /// serializes the launch through `isOpeningReal` so two near-simultaneous forwards — or a
    /// forward and the `openReal` button — can't both `open -n` a duplicate default (which
    /// shares no `shlock` and would corrupt its LevelDB); the slot is held across the poll +
    /// deliver and released via the forwarder's `release` once the instance is reachable.
    private func forwardToDefaultAccount(url: URL) async {
        guard !launchBlockedByStagedApply() else { return }
        let forwarder = DeepLinkForwarder(
            probePID: { [weak self] in await self?.defaultPID() },
            launch: { [weak self] in await self?.acquireDefaultLaunchSlot() ?? .failed },
            release: { [weak self] in await self?.releaseDefaultLaunchSlot() },
            deliver: { [weak self] url, pid in
                guard let self else { return .targetGone }
                return await sendGURL(url, toPID: pid)
            },
            sleep: { try? await Task.sleep(for: $0) },
            log: { Log.deepLink.info("forwardToDefaultAccount: \($0, privacy: .public)") }
        )
        await applyOutcome(forwarder.forward(url), targetName: Self.defaultAccountName)
    }

    /// Acquire the default-account launch slot and `open -n` a fresh instance. The
    /// `isOpeningReal` check-and-set is a single synchronous main-actor step (no `await`
    /// between the read and the write), so two forwards — or a forward and the `openReal`
    /// button — can't both launch. `.started` means this call holds the slot; the forwarder
    /// releases it (via `releaseDefaultLaunchSlot`) after the poll + deliver. A failed
    /// `open -n` releases it here, since there is nothing to poll for.
    private func acquireDefaultLaunchSlot() async -> DeepLinkForwarder.LaunchResult {
        guard !isOpeningReal else { return .alreadyInFlight }
        isOpeningReal = true
        if await perform({ try $0.openReal() }) != nil { return .started }
        isOpeningReal = false
        return .failed
    }

    private func releaseDefaultLaunchSlot() {
        isOpeningReal = false
    }

    /// Send the GURL off the main actor (the first send blocks on the TCC prompt), returning
    /// the failure — or `nil` on success — for the forwarder to fold into its `Outcome`.
    private func sendGURL(_ url: URL, toPID pid: Int32) async -> DeepLinkDeliveryFailure? {
        await Task.detached {
            do {
                try DeepLinkDelivery.send(url, toPID: pid_t(pid))
                return nil
            } catch let failure as DeepLinkDeliveryFailure {
                return failure
            } catch {
                return .sendFailed(code: (error as NSError).code)
            }
        }.value
    }

    /// Map a forward `Outcome` to user-facing state. `.launchFailed` is silent on purpose —
    /// the failed launch already surfaced its own error via `perform`, so don't stack a
    /// "couldn't reach" notice on top.
    private func applyOutcome(_ outcome: DeepLinkForwarder.Outcome, targetName: String) {
        switch outcome {
        case .delivered, .launchFailed:
            break // delivered — Claude routes it to the right window itself
        case .neverAppeared:
            // Log at error (the forwarder's info-level trace mirrors this, but a genuine
            // delivery failure belongs in an error-level Console filter).
            Log.deepLink.error("delivery to \(targetName, privacy: .public) failed: instance never came up")
            currentError = AppError(
                message: "Couldn't reach \(targetName) after launching it. Reopen the link once it's up."
            )
        case .deliveryFailed(.notPermitted):
            currentError = AppError(message: Self.automationDeniedMessage)
        case .deliveryFailed(.targetGone):
            currentError = AppError(
                message: "Couldn't deliver the link — \(targetName) quit first. Reopen it to retry."
            )
        case let .deliveryFailed(.sendFailed(code)):
            currentError = AppError(
                message: "Couldn't deliver the link to \(targetName) (error \(code)). Reopen it to retry."
            )
        }
    }

    private func pid(for profile: Profile) async -> Int32? {
        await perform { store in store.runningPID(for: profile) }.flatMap(\.self)
    }

    private func defaultPID() async -> Int32? {
        await perform { store in store.runningDefaultPID() }.flatMap(\.self)
    }

    private static let defaultAccountName = "the default account"

    private static let automationDeniedMessage =
        "Claude Manager needs permission to control Claude to hand off the link. Allow it under "
            + "System Settings ▸ Privacy & Security ▸ Automation, then reopen the link."
}

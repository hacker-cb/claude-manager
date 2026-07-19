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
    /// every launch mode, including window-less logins where `RootView.task` never fires;
    /// bounded so a pathological launch can't loop forever.
    func wireDeepLinkHandler(attempt: Int = 0) {
        guard let delegate = AppDelegate.shared else {
            guard attempt < 200 else {
                Log.deepLink
                    .error(
                        "deepLinkHandler never wired: AppDelegate.shared nil after \(attempt, privacy: .public) attempts"
                    )
                return
            }
            DispatchQueue.main.async { [weak self] in self?.wireDeepLinkHandler(attempt: attempt + 1) }
            return
        }
        delegate.deepLinkHandler = { [weak self] urls in self?.handleDeepLinks(urls) }
        Log.deepLink.info("deepLinkHandler wired after \(attempt, privacy: .public) retry(ies)")
    }

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
        // Running → hand the link straight to that instance via a GURL Apple event. A clone's
        // launcher is `shlock`-guarded, so a not-running clone is safe to just cold-launch,
        // then deliver once it registers.
        if let pid = await pid(for: profile) {
            Log.deepLink
                .info(
                    "forwardToProfile(\(profile.displayName, privacy: .public)): running (pid \(pid, privacy: .public)) → GURL"
                )
            await deliverGURL(url, toPID: pid, targetName: profile.displayName)
            return
        }
        Log.deepLink
            .info(
                "forwardToProfile(\(profile.displayName, privacy: .public)): not running → cold-launch then GURL"
            )
        _ = await perform { store in try store.open(profile) }
        await launchThenDeliver(url, targetName: profile.displayName) { [weak self] in
            await self?.pid(for: profile)
        }
    }

    /// Forward to the default account (the untouched real app). Running → GURL to its pid;
    /// not running → cold-launch, then deliver once it's up. The launch is serialized through
    /// `isOpeningReal` so two near-simultaneous forwards can't both `open -n` a duplicate
    /// default (which shares no `shlock` and would corrupt its LevelDB).
    private func forwardToDefaultAccount(url: URL) async {
        guard !launchBlockedByStagedApply() else { return }
        if let pid = await defaultPID() {
            Log.deepLink.info("forwardToDefaultAccount: running (pid \(pid, privacy: .public)) → GURL")
            await deliverGURL(url, toPID: pid, targetName: Self.defaultAccountName)
            return
        }
        // A launch is already in flight (a prior forward or `openReal`) — don't start another;
        // just wait for that instance to come up and deliver to it.
        guard !isOpeningReal else {
            Log.deepLink.info("forwardToDefaultAccount: launch already in flight → wait then GURL")
            await launchThenDeliver(url, targetName: Self.defaultAccountName) { [weak self] in
                await self?.defaultPID()
            }
            return
        }
        isOpeningReal = true
        defer { isOpeningReal = false }
        Log.deepLink.info("forwardToDefaultAccount: not running → cold-launch then GURL")
        _ = await perform { store in try store.openReal() }
        await launchThenDeliver(url, targetName: Self.defaultAccountName) { [weak self] in
            await self?.defaultPID()
        }
    }

    /// Poll for a just-launched instance's pid (bounded), then deliver the link to it. A
    /// launch that never registers surfaces a notice rather than hanging.
    private func launchThenDeliver(
        _ url: URL, targetName: String, pidProbe: @escaping () async -> Int32?
    ) async {
        for _ in 0 ..< 40 { // ~12s at 300ms between probes
            guard let pid = await pidProbe() else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            // Give Electron a moment to install its `open-url` handler. Claude stashes a
            // cold-start URL that arrives before its window is ready, so this settle need
            // only be approximate, not exact.
            try? await Task.sleep(for: .milliseconds(700))
            await deliverGURL(url, toPID: pid, targetName: targetName)
            return
        }
        Log.deepLink
            .error(
                "launchThenDeliver(\(targetName, privacy: .public)): instance never came up — not delivered"
            )
        currentError = AppError(
            message: "Couldn't reach \(targetName) after launching it. Reopen the link once it's up."
        )
    }

    /// Send the GURL off the main actor (the first send blocks on the TCC prompt), mapping a
    /// denial to actionable guidance instead of a silent drop.
    private func deliverGURL(_ url: URL, toPID pid: Int32, targetName: String) async {
        let failure: DeepLinkDelivery.Failure? = await Task.detached {
            do {
                try DeepLinkDelivery.send(url, toPID: pid_t(pid))
                return nil
            } catch let failure as DeepLinkDelivery.Failure {
                return failure
            } catch {
                return .sendFailed(code: (error as NSError).code)
            }
        }.value
        switch failure {
        case .none:
            break // delivered — Claude routes it to the right window itself
        case .notPermitted:
            currentError = AppError(message: Self.automationDeniedMessage)
        case .targetGone:
            currentError = AppError(
                message: "Couldn't deliver the link — \(targetName) quit first. Reopen it to retry."
            )
        case let .sendFailed(code):
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

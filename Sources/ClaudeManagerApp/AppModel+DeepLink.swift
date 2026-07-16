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
        guard !claudeURLs.isEmpty else { return }
        guard deepLinkBrokerEnabled else {
            // Broker off, but we still declare the scheme, so a link can reach us — hand it
            // to the default account. Forward only the *first* of a batch: macOS can't
            // deliver to the instance we're about to launch, and a second `open -n` would
            // spawn a duplicate default on one user-data-dir (LevelDB corruption). The
            // per-call running-PID probe lags process startup, so it can't catch the second.
            Task {
                let delivered = await forwardToDefaultAccount(url: claudeURLs[0])
                // Only note the dropped extras if the first actually launched — otherwise
                // `forwardToDefaultAccount` already set a more important error (default
                // running, or a staged-update apply in progress) that must not be masked.
                if delivered, claudeURLs.count > 1 {
                    currentError = AppError(message: Self.batchDeliveryLimitMessage(claudeURLs.count))
                }
                await refresh()
            }
            return
        }
        pendingDeepLinkQueue.append(contentsOf: claudeURLs)
        presentNextDeepLinkIfIdle()
    }

    /// Idempotent launch work: start monitoring, paint the list, and apply the deep-link
    /// broker (grab the `claude://` handler). Runs once — from `init` on every launch
    /// (window or not) and, as a fallback, from `RootView.task`.
    func performLaunchTasks() async {
        guard !didPerformLaunch else { return }
        didPerformLaunch = true
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
            deepLinkService.startHolding()
        } else {
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
        guard !deepLinkPresenter.isPresenting, !pendingDeepLinkQueue.isEmpty else { return }
        deepLinkPresenter.reserve()
        let url = pendingDeepLinkQueue.removeFirst()
        Task { await presentPicker(for: url) }
    }

    private func presentPicker(for url: URL) async {
        // Always refresh so a since-deleted profile is never offered as a target.
        await refresh()
        // Default account first, matching the sidebar and menu-bar ordering.
        let targets: [DeepLinkTarget] = [.defaultAccount] + profiles.map { .profile($0.profile) }
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
        guard !launchBlockedByStagedApply() else { return }
        // A running target can't receive the link: the launcher's duplicate guard exits
        // without forwarding. Tell the user rather than silently dropping it.
        if let pid = await pid(for: profile) {
            currentError = AppError(message: deliveryToRunningMessage(profile.displayName, pid: pid))
            return
        }
        _ = await perform { store in try store.openForwarding(profile, url: url.absoluteString) }
    }

    /// Forward to the default account, returning whether the link was actually launched
    /// (`false` when refused: mid staged-apply, a concurrent open, or the default already
    /// running). The caller uses this to avoid masking a refusal's error with a notice.
    @discardableResult
    private func forwardToDefaultAccount(url: URL) async -> Bool {
        guard !launchBlockedByStagedApply() else { return false }
        // Same running-instance limitation, plus: a second `open -n` on a live default
        // would corrupt its user-data-dir. Share `openReal`'s serialization guard so a
        // concurrent openReal or a second forward can't both pass the probe and launch a
        // duplicate default (the probe → launch window is otherwise a TOCTOU race).
        guard !isOpeningReal else { return false }
        isOpeningReal = true
        defer { isOpeningReal = false }
        if let pid = await perform({ store in store.runningDefaultPID() }).flatMap(\.self) {
            currentError = AppError(message: deliveryToRunningMessage("the default account", pid: pid))
            return false
        }
        return await perform { store in try store.openRealForwarding(url: url.absoluteString) } != nil
    }

    private func pid(for profile: Profile) async -> Int32? {
        await perform { store in store.runningPID(for: profile) }.flatMap(\.self)
    }

    private func deliveryToRunningMessage(_ name: String, pid: Int32) -> String {
        "\(name) is already running (pid \(pid)). macOS can't deliver a deep link to a "
            + "running Claude instance — quit it first, then reopen the link."
    }

    private static func batchDeliveryLimitMessage(_ count: Int) -> String {
        "Opened the first of \(count) links in the default account. macOS can deliver only "
            + "one link per launch — reopen the rest once it's running."
    }
}

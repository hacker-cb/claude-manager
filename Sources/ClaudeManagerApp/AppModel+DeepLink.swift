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
            Task {
                for url in claudeURLs {
                    await forwardToDefaultAccount(url: url)
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

    /// Present the next queued link's picker when nothing is already on screen.
    private func presentNextDeepLinkIfIdle() {
        guard !deepLinkPresenter.isPresenting, !pendingDeepLinkQueue.isEmpty else { return }
        let url = pendingDeepLinkQueue.removeFirst()
        Task { await presentPicker(for: url) }
    }

    private func presentPicker(for url: URL) async {
        // Always refresh so a since-deleted profile is never offered as a target.
        await refresh()
        let targets: [DeepLinkTarget] = profiles.map { .profile($0.profile) } + [.defaultAccount]
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
        // A running target can't receive the link: the launcher's duplicate guard exits
        // without forwarding. Tell the user rather than silently dropping it.
        if let pid = await pid(for: profile) {
            currentError = AppError(message: deliveryToRunningMessage(profile.displayName, pid: pid))
            return
        }
        _ = await perform { store in try store.openForwarding(profile, url: url.absoluteString) }
    }

    private func forwardToDefaultAccount(url: URL) async {
        // Same running-instance limitation, plus: a second `open -n` on a live default
        // would corrupt its user-data-dir. Share `openReal`'s serialization guard so a
        // concurrent openReal or a second forward can't both pass the probe and launch a
        // duplicate default (the probe → launch window is otherwise a TOCTOU race).
        guard !isOpeningReal else { return }
        isOpeningReal = true
        defer { isOpeningReal = false }
        if let pid = await perform({ store in store.runningDefaultPID() }).flatMap(\.self) {
            currentError = AppError(message: deliveryToRunningMessage("the default account", pid: pid))
            return
        }
        _ = await perform { store in try store.openRealForwarding(url: url.absoluteString) }
    }

    private func pid(for profile: Profile) async -> Int32? {
        await perform { store in store.runningPID(for: profile) }.flatMap(\.self)
    }

    private func deliveryToRunningMessage(_ name: String, pid: Int32) -> String {
        "\(name) is already running (pid \(pid)). macOS can't deliver a deep link to a "
            + "running Claude instance — quit it first, then reopen the link."
    }
}

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
    /// Handle inbound deep links from `AppDelegate`. Only `claude://` URLs are routed;
    /// anything else is ignored. One link at a time gets a picker.
    func handleDeepLinks(_ urls: [URL]) {
        let claudeURLs = urls.filter { DeepLink.isClaudeURL($0.absoluteString) }
        guard let url = claudeURLs.first else { return }
        Task { await presentPicker(for: url) }
    }

    /// Pre-seed every clone's managed-config overlay (disable its Squirrel updater; with
    /// the broker on, its deep-link registration too) so existing installs pick it up
    /// without an explicit rebuild. Best-effort and off the main actor; a per-profile
    /// write failure is surfaced later by `Doctor`, not as an alert here.
    func reconcileManagedConfigs() async {
        _ = await perform { store in store.reconcileAllManagedConfigs() }
    }

    /// Register / restore the handler and reconcile the overlays for the current broker
    /// setting. Called from the Settings toggle and at startup.
    func applyDeepLinkBroker() async {
        _ = await perform { store in store.reconcileAllManagedConfigs() }
        if deepLinkBrokerEnabled {
            deepLinkService.startHolding()
        } else {
            deepLinkService.stopHoldingAndRestore(to: realClaude)
        }
    }

    /// Start holding the handler at launch if the broker is enabled (the overlays are
    /// reconciled separately by `reconcileManagedConfigs`).
    func startDeepLinkBrokerIfEnabled() {
        guard deepLinkBrokerEnabled else { return }
        deepLinkService.startHolding()
    }

    // MARK: - Picker + forwarding

    private func presentPicker(for url: URL) async {
        if profiles.isEmpty { await refresh() }
        let targets: [DeepLinkTarget] = profiles.map { .profile($0.profile) } + [.defaultAccount]
        deepLinkPresenter.present(url: url, targets: targets) { [weak self] target in
            Task { await self?.forwardDeepLink(url, to: target) }
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
        // would corrupt its user-data-dir — so refuse when it's already running.
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

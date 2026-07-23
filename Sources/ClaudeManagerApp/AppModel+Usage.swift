import ClaudeManagerCore
import Foundation

/// Plan-usage wiring on the app model: the poll loop, the master-switch gate, and the merge of
/// `UsageService` results into published per-binding state. `UsageService` itself is stateless
/// and rebuilt each tick; the durable actors (`usageHistory`, `safeStorageKeys`) are held by the
/// model. The app owns the loop — the core does not self-poll.
extension AppModel {
    /// The app's marketing version, sent as the `User-Agent` on usage calls.
    static let usageMarketingVersion = Bundle.main
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// `~/Library/Application Support/Claude Manager/usage.db`, creating the directory.
    static func usageDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        let directory = support.appendingPathComponent(
            CoreConstants.appSupportDirectoryName,
            isDirectory: true
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.db")
    }

    // MARK: - Poll loop (mirrors monitorTask)

    /// Start (or no-op if already running / disabled / manual-only). Fetches immediately so an
    /// already-authorized user sees usage at once — the background path uses
    /// `kSecUseAuthenticationUISkip`, so a first launch that isn't yet keychain-authorized fails
    /// fast (no prompt) rather than blocking; the prompt is deferred to an interactive Refresh.
    func startUsagePolling() {
        guard usagePollTask == nil, usageTrackingEnabled, usagePollIntervalMinutes > 0 else { return }
        usagePollTask = Task { @MainActor [weak self] in
            if let self { await pollUsageOnce() } // immediate, so returning users see usage now
            while !Task.isCancelled {
                // Re-check weak self each iteration (don't hold it strong across the sleep).
                let seconds = self?.usagePollSleepInterval() ?? (30 * 60)
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                await pollUsageOnce()
            }
        }
    }

    private func pollUsageOnce() async {
        guard usageTrackingEnabled, usagePollIntervalMinutes > 0, !isApplyingStagedUpdate else { return }
        await refreshUsage(interactive: false)
        await usageHistory.prune(now: Date())
    }

    func stopUsagePolling() {
        usagePollTask?.cancel()
        usagePollTask = nil
    }

    func restartUsagePolling() {
        stopUsagePolling()
        startUsagePolling()
    }

    /// React to the master switch: start when enabled, stop + clear published state when off (so
    /// the UI hides usage and nothing is read/called/stored).
    func applyUsageTrackingChange() {
        if usageTrackingEnabled {
            startUsagePolling()
        } else {
            stopUsagePolling()
            usageByBinding = [:]
            usageBindingFailures = [:]
        }
    }

    /// Seconds until the next poll: the chosen interval, halved to the adaptive 5-min cadence
    /// while any account is running (actively used) — bounded by the interval so a longer
    /// interval is never made *slower* by adaptivity.
    func usagePollSleepInterval() -> TimeInterval {
        let base = TimeInterval(max(1, usagePollIntervalMinutes) * 60)
        guard usageAdaptiveEnabled else { return base }
        let anyRunning = primaryAccount?.isRunning == true || profiles.contains(where: \.isRunning)
        return anyRunning ? min(base, 5 * 60) : base
    }

    // MARK: - Refresh

    /// One refresh pass, merged into `usageByBinding`. `interactive` allows the one-time keychain
    /// prompt (a user gesture); the background loop passes `false`.
    func refreshUsage(interactive: Bool) async {
        // Master switch is the choke point: off → read nothing, call nothing, store nothing.
        guard usageTrackingEnabled else { return }
        // Single-flight: a manual Refresh overlapping a scheduled poll must not both fetch.
        guard !isRefreshingUsage else { return }
        guard realClaude != nil, let config = currentConfiguration() else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        let bindings = usageBindings(config: config)
        guard !bindings.isEmpty else { return }
        let result = await makeUsageService().refresh(bindings: bindings, interactive: interactive)

        var byBinding: [String: AccountUsage] = [:]
        for account in result.accounts {
            for bindingID in account.bindingIDs {
                byBinding[bindingID] = account
            }
        }
        usageByBinding = byBinding
        usageBindingFailures = result.bindingFailures
    }

    // MARK: - Wiring

    private func makeUsageService() -> UsageService {
        UsageService(
            resolver: AccountResolver(provider: DesktopSafeStorageProvider(keyStore: safeStorageKeys)),
            client: AnthropicOAuthClient(),
            keyStore: safeStorageKeys,
            history: usageHistory,
            marketingVersion: Self.usageMarketingVersion
        )
    }

    /// The default account plus every managed profile, each pointed at its `config.json`.
    private func usageBindings(config: ProfileStoreConfiguration) -> [TokenBinding] {
        var bindings = [TokenBinding(
            id: TokenBinding.defaultID,
            configURL: URL(fileURLWithPath: config.defaultAccountUserDataPath)
                .appendingPathComponent("config.json")
        )]
        for managed in profiles {
            bindings.append(TokenBinding(
                id: managed.profile.id,
                configURL: managed.profile.profileURL.appendingPathComponent("config.json")
            ))
        }
        return bindings
    }

    // MARK: - View accessors

    /// Usage for a binding (a profile's launcher path, or `TokenBinding.defaultID`).
    func usage(forBinding id: String) -> AccountUsage? {
        usageByBinding[id]
    }

    /// Why a binding couldn't produce a token, if it failed to.
    func usageFailure(forBinding id: String) -> TokenProviderError? {
        usageBindingFailures[id]
    }
}

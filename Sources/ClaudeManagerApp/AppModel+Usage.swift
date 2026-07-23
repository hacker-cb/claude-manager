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

    /// `~/Library/Application Support/Claude Manager/usage.db`, creating the directory. Shares
    /// `MetadataStore.defaultDirectory()` so usage.db always lands beside metadata.json / Profiles
    /// rather than re-deriving (and risking drifting from) the app-support location.
    static func usageDatabaseURL() -> URL {
        let directory = MetadataStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    /// Seconds until the next poll — the cadence math lives in (and is tested in) the core; the
    /// app only supplies the running-accounts fact it can't compute headless.
    func usagePollSleepInterval() -> TimeInterval {
        let anyRunning = primaryAccount?.isRunning == true || profiles.contains(where: \.isRunning)
        return UsageService.pollIntervalSeconds(
            minutes: usagePollIntervalMinutes,
            adaptiveEnabled: usageAdaptiveEnabled,
            anyRunning: anyRunning
        )
    }

    // MARK: - Refresh

    /// One refresh pass, merged into `usageByBinding`. `interactive` allows the one-time keychain
    /// prompt (a user gesture); the background loop passes `false`.
    func refreshUsage(interactive: Bool) async {
        // Master switch is the choke point: off → read nothing, call nothing, store nothing.
        guard usageTrackingEnabled else { return }
        guard realClaude != nil, let config = currentConfiguration() else { return }

        // Single-flight — but an interactive request must never be silently dropped: it is the
        // only path that can raise the one-time keychain prompt. If a refresh is already running,
        // record that an interactive pass is still owed and let the current one finish first.
        if isRefreshingUsage {
            if interactive { pendingInteractiveRefresh = true }
            return
        }
        isRefreshingUsage = true

        let result = await makeUsageService().refresh(
            bindings: usageBindings(config: config), interactive: interactive
        )

        // The master switch can flip off during the await; honor it so we neither repopulate the
        // state `applyUsageTrackingChange` just cleared nor fire notifications after "off".
        if usageTrackingEnabled {
            var byBinding: [String: AccountUsage] = [:]
            for account in result.accounts {
                for bindingID in account.bindingIDs {
                    byBinding[bindingID] = account
                }
            }
            usageByBinding = byBinding
            usageBindingFailures = result.bindingFailures
            await notifyLimits(for: result.accounts)
        }

        let owedInteractive = pendingInteractiveRefresh
        pendingInteractiveRefresh = false
        isRefreshingUsage = false
        // Honor an interactive Refresh that arrived mid-flight — run it now that the slot is free.
        if owedInteractive, usageTrackingEnabled { await refreshUsage(interactive: true) }
    }

    // MARK: - Menu-bar summary

    /// The worst active limit across all accounts, as `7d 54%` — the at-a-glance value shown in
    /// the status bar. Nil when tracking is off or there's no data yet.
    var menuBarUsageSummary: (label: String, fraction: Double)? {
        guard usageTrackingEnabled else { return nil }
        let worst = usageByBinding.values
            .compactMap(\.displayLimit)
            .max { $0.utilization < $1.utilization }
        guard let worst else { return nil }
        return ("\(worst.shortLabel) \(UsageFormat.percent(worst.utilization))", worst.utilization)
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

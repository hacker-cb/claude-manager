import ClaudeManagerCore
import Foundation

/// Plan-usage wiring on the app model: the poll loop, the master-switch gate, and the merge of
/// `UsageService` results into published per-binding state. `UsageService` itself is stateless
/// and rebuilt each tick; the durable actors (`usageHistory`, `safeStorageKeys`) are held by the
/// model. The app owns the loop — the core does not self-poll.
extension AppModel {
    /// The app's marketing version, sent as the `User-Agent` on usage calls. Falls back to the
    /// shared dev placeholder rather than a second literal, so the two can't drift.
    static let usageMarketingVersion = Bundle.main
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? CoreConstants.devMarketingVersion

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
                // Read the cadence through weak self and drop it again before sleeping — the
                // model must stay collectable across the wait, and if it's already gone there
                // is nothing left to poll.
                guard let seconds = self?.usagePollSleepInterval() else { return }
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
            // Also stop a pass already in flight: it would otherwise finish its remaining
            // per-account calls and write their rows after the user said stop.
            usageRefreshTask?.cancel()
            usageRefreshTask = nil
            // Disown that pass so it can't repopulate the state we clear below when it resumes,
            // and release the single-flight lock + interactive debt — otherwise re-enabling
            // tracking is swallowed by the `isRefreshingUsage` guard the dead pass never cleared,
            // and no fetch happens until the next scheduled poll.
            usageRefreshGeneration += 1
            isRefreshingUsage = false
            pendingInteractiveRefresh = false
            usageByBinding = [:]
            usageBindingFailures = [:]
        }
    }

    /// Seconds until the next poll — the cadence math lives in (and is tested in) the core; the
    /// app only supplies the running-accounts fact it can't compute headless.
    func usagePollSleepInterval() -> TimeInterval {
        UsageService.pollIntervalSeconds(
            minutes: usagePollIntervalMinutes,
            adaptiveEnabled: usageAdaptiveEnabled,
            anyRunning: anyProfileRunning
        )
    }

    /// Any profile — the default or a clone — currently running. It drives the adaptive cadence,
    /// which the sleep-interval math and the running-set-change check must read the same way.
    var anyProfileRunning: Bool {
        primaryProfile?.isRunning == true || profiles.contains(where: \.isRunning)
    }

    // MARK: - Refresh

    /// Called after every list refresh. Resolves usage **only when the launcher set changed** —
    /// a newly added account otherwise has neither usage nor a failure to show, and would sit
    /// unexplained until the next tick (forever, under "Manually only"). An unchanged set does
    /// nothing: usage is driven by its own interval, never by a list refresh, which also fires
    /// automatically (launch, activation, after open/stop) and would both defeat "Manually only"
    /// and raise the keychain prompt at launch. Non-interactive for that same reason — adding a
    /// launcher must never pop an authorization dialog.
    func refreshUsageIfBindingsChanged() async {
        // The running set decides the cadence, and the sleeping poll task computed its interval
        // before that changed. Opening an account would otherwise wait out the whole idle
        // interval — up to an hour — before the 5-minute lane the settings promise kicks in.
        let running = anyProfileRunning
        if running != lastKnownAnyRunning {
            lastKnownAnyRunning = running
            if usageAdaptiveEnabled { restartUsagePolling() }
        }

        let current = Set(profiles.map(\.profile.id))
        guard current != lastKnownBindingIDs else { return }
        guard usageTrackingEnabled, usagePollIntervalMinutes > 0 else {
            lastKnownBindingIDs = current // nothing to fetch in this mode; don't re-check forever
            return
        }
        // Committed only once the refresh has actually run. Recording it up front meant a pass
        // dropped by the single-flight guard consumed the change, and the new launcher was never
        // fetched at all.
        guard !isRefreshingUsage else { return }
        lastKnownBindingIDs = current
        await refreshUsage(interactive: false)
    }

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
        // Snapshot the generation before suspending: a master-switch toggle-off (or off→on) while
        // this pass is awaited bumps it, marking this pass superseded so it commits nothing on
        // resume.
        let generation = usageRefreshGeneration

        // Run the pass as a tracked child task so the master switch can cancel it. The poll loop
        // is cancellable on its own, but a manual Refresh runs in a task the view owns, and the
        // service checks `Task.isCancelled` between accounts.
        let service = makeUsageService()
        let bindings = usageBindings(config: config)
        let task = Task { await service.refresh(bindings: bindings, interactive: interactive) }
        usageRefreshTask = task
        let result = await task.value

        // Superseded while suspended → the toggle-off that disowned this pass already cleared the
        // state and reset the lock (or a newer pass now owns it). Commit nothing and touch none of
        // the shared refresh state.
        guard generation == usageRefreshGeneration else { return }
        usageRefreshTask = nil

        // The master switch can flip off during the await; honor it so we neither repopulate the
        // state `applyUsageTrackingChange` just cleared nor fire notifications after "off".
        if usageTrackingEnabled {
            var byBinding: [String: AccountUsage] = [:]
            for account in result.accounts {
                for bindingID in account.bindingIDs {
                    byBinding[bindingID] = account
                }
            }
            // A binding whose token couldn't be read this pass (a keychain that locked mid-session,
            // say) is absent from `result.accounts`. Replacing wholesale would blank its numbers,
            // which is the opposite of the serve-stale promise — so keep the last snapshot, but
            // restate it as `.noSource`: the figures stay, and both the detail pane and the
            // sidebar say an action is needed rather than passing them off as current.
            for id in result.bindingFailures.keys {
                guard byBinding[id] == nil, var kept = usageByBinding[id],
                      kept.snapshot != nil else { continue }
                kept.state = .noSource
                byBinding[id] = kept
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
    /// Only accounts whose numbers are current are quoted here: a status-bar percentage carries
    /// no hint that it stopped moving, so a stale, offline, rate-limited or signed-out account
    /// must not contribute one.
    var menuBarUsageSummary: (label: String, fraction: Double)? {
        guard usageTrackingEnabled else { return nil }
        let worst = usageByBinding.values
            .filter(\.isQuotableNow)
            .compactMap(\.displayLimit)
            .max { $0.utilization < $1.utilization }
        guard let worst else { return nil }
        return (UsageFormat.limitSummary(worst), worst.utilization)
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
            configURL: URL(fileURLWithPath: config.defaultProfileUserDataPath)
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

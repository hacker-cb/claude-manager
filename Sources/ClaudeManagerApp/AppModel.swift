import AppKit
import ClaudeManagerCore
import SwiftUI
import UserNotifications

/// A user-facing error wrapped for `.alert(item:)`.
struct AppError: Identifiable {
    let id = UUID()
    let message: String

    init(message: String) {
        self.message = message
    }

    /// Prefer a domain error's `errorDescription` over the opaque `localizedDescription`.
    init(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A message-carrying error so a thrown failure can surface a specific reason (e.g.
/// the concrete `locateError`) through the editor's alert instead of a generic one.
struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

/// The single source of view state. All blocking core operations are dispatched
/// off the main actor (`perform`) so the UI never stalls; results and errors are
/// published back on the main actor.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [ManagedProfile] = []
    /// Observable state of the default profile (the untouched real app), shown as the first
    /// row of the profile lists. `nil` when Claude.app can't be located.
    @Published private(set) var primaryProfile: PrimaryProfileStatus?
    @Published private(set) var realClaude: RealClaude?
    @Published private(set) var realClaudeVersion: String?

    /// The sidebar's profile rows: the default profile first (whenever Claude is located —
    /// provisionally "stopped" until the next status probe fills `primaryProfile` in), then
    /// each managed clone. Keyed off `realClaude`, not `primaryProfile`, so a Retry that
    /// re-finds Claude shows the default row at once instead of waiting for a refresh. The
    /// menu bar renders the same ordering directly, since its per-item affordances differ.
    var profileEntries: [ProfileEntry] {
        guard realClaude != nil else { return profiles.map(ProfileEntry.clone) }
        let primary = primaryProfile ?? PrimaryProfileStatus(pid: nil)
        return [.primary(primary)] + profiles.map(ProfileEntry.clone)
    }

    @Published var locateError: String?
    @Published private(set) var isBusy = false
    @Published var currentError: AppError?

    /// Number of in-flight operations; `isBusy` tracks it. A shared Bool would let
    /// a fast operation clear the spinner while a slow one (e.g. a ~10s stop) runs.
    /// Non-private so the `AppModel+Perform` extension (another file) can drive it.
    var inflight = 0 {
        didSet { isBusy = inflight > 0 }
    }

    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var runningInstances: [ClaudeInstance] = []

    /// A Claude update ShipIt has staged but not applied (any open profile blocks the
    /// swap) — drives the "Apply to all profiles" affordance. `nil` when none.
    @Published private(set) var stagedUpdate: StagedUpdate?
    /// True while a coordinated apply is in flight, so the UI disables re-triggering and
    /// the background monitor pauses (a relaunch mid-swap would trip ShipIt's Gate 2).
    @Published private(set) var isApplyingStagedUpdate = false
    /// Staged versions already surfaced as a notification, so it nags once per version.
    var notifiedStagedUpdate: Set<String> = []

    /// Flip the apply-in-flight flag (`private(set)`, so the extension drives it via this).
    func setApplyingStagedUpdate(_ value: Bool) {
        isApplyingStagedUpdate = value
    }

    /// Update keys ("`appPath@targetVersion`") already surfaced as a notification, so
    /// a pending update nags once — not on every refresh. A skew that resolves (the
    /// instance was restarted) drops out, so a later update notifies afresh.
    /// Non-private for the `AppModel+StagedUpdate` extension, which owns the update
    /// notifications.
    var notifiedClaudeUpdates: Set<String> = []
    var monitorTask: Task<Void, Never>?
    var activationObserver: (any NSObjectProtocol)?

    /// Serializes `openReal`: `@MainActor` makes its check-and-set atomic, so two
    /// overlapping runs can't both `open -n` a duplicate default. See `openReal`.
    /// Non-private so the `AppModel+PrimaryProfile` extension (another file) can reach it.
    var isOpeningReal = false

    // MARK: - Plan-usage statistics (see AppModel+Usage)

    /// Durable for the process lifetime: the SQLite history/throttle store, and the safeStorage
    /// key cache (one keychain read for the whole fleet).
    let usageHistory: UsageHistoryStore
    let safeStorageKeys = SafeStorageKeyStore()

    /// Latest usage per **binding** id (launcher path / default-profile id); one Claude login
    /// shared across profiles appears under each of its bindings, so a view keyed by profile
    /// reads it directly.
    @Published var usageByBinding: [String: AccountUsage] = [:]
    /// Per-binding token failures (login-needed / no-source), for a profile row's state.
    @Published var usageBindingFailures: [String: TokenProviderError] = [:]

    /// The background usage poll; mirrors `monitorTask`. Non-private for `AppModel+Usage`.
    var usagePollTask: Task<Void, Never>?
    /// Single-flights `refreshUsage`: `@MainActor` makes the check-and-set atomic, so a manual
    /// Refresh overlapping a scheduled poll can't both fetch. `@Published` because the detail
    /// panes bind it to disable the Refresh button and show "Checking usage…" — without it those
    /// views wouldn't re-render when a manual refresh starts or finishes.
    @Published var isRefreshingUsage = false
    /// Set when an interactive Refresh arrives mid-flight, so one more interactive round follows.
    var pendingInteractiveRefresh = false
    /// Bumped whenever the master switch disowns the pass in flight (toggle-off, or off→on). A
    /// pass suspended on its `await` compares this after resuming and, if it changed, commits
    /// nothing and leaves the single-flight state to whoever owns the current generation — so a
    /// cancelled pass can't repopulate state the toggle-off just cleared, nor hold the lock shut.
    var usageRefreshGeneration = 0
    /// The usage pass in flight, so the master switch can cancel it mid-fleet. The two `lastKnown`
    /// values are the previous resolve's launcher set and running-state, to spot a change.
    var usageRefreshTask: Task<UsageRefreshResult, Never>?
    var lastKnownBindingIDs: Set<String> = []
    var lastKnownAnyRunning = false
    /// When usage history was last pruned, so the retention sweep runs on a coarse schedule
    /// (`usagePruneInterval`) rather than on every poll tick.
    var lastUsagePruneAt: Date?

    @Published var usageTrackingEnabled: Bool {
        didSet {
            defaults.set(usageTrackingEnabled, forKey: PreferenceKeys.usageTrackingEnabled)
            guard didFinishInit else { return }
            applyUsageTrackingChange()
        }
    }

    /// Background poll interval in minutes; `0` = manual only. Presets in Settings.
    @Published var usagePollIntervalMinutes: Int {
        didSet {
            defaults.set(usagePollIntervalMinutes, forKey: PreferenceKeys.usagePollIntervalMinutes)
            guard didFinishInit else { return }
            restartUsagePolling()
        }
    }

    @Published var usageAdaptiveEnabled: Bool {
        didSet {
            defaults.set(usageAdaptiveEnabled, forKey: PreferenceKeys.usageAdaptiveEnabled)
            guard didFinishInit else { return }
            restartUsagePolling()
        }
    }

    /// Whether limit-approaching reminders are posted. On by default.
    @Published var usageNotificationsEnabled: Bool {
        didSet { defaults.set(usageNotificationsEnabled, forKey: PreferenceKeys.usageNotificationsEnabled) }
    }

    @Published var measureSizes: Bool {
        didSet { defaults.set(measureSizes, forKey: PreferenceKeys.measureSizes) }
    }

    @Published var installOverridePath: String {
        didSet { defaults.set(installOverridePath, forKey: PreferenceKeys.installDirectoryOverride) }
    }

    @Published var profilesOverridePath: String {
        didSet { defaults.set(profilesOverridePath, forKey: PreferenceKeys.profilesDirectoryOverride) }
    }

    /// Global badge look. Persisted as JSON; new and rebuilt launcher icons use it.
    @Published var badgeStyle: BadgeStyle {
        didSet { persistBadgeStyle() }
    }

    /// Whether the `claude://` deep-link broker owns the handler (on by default). Changing it
    /// after launch reconciles the overlays and grabs / restores the handler.
    @Published var deepLinkBrokerEnabled: Bool {
        didSet {
            defaults.set(deepLinkBrokerEnabled, forKey: PreferenceKeys.deepLinkBrokerEnabled)
            guard didFinishInit else { return }
            scheduleBrokerApply()
        }
    }

    /// App-layer wiring for the broker (handler registration + hold/restore). Non-private
    /// so the `AppModel+DeepLink` extension can reach it.
    let deepLinkService = DeepLinkService()
    let deepLinkPresenter = DeepLinkPresenter()
    /// Inbound `claude://` links awaiting a picker, shown one at a time.
    var pendingDeepLinkQueue: [URL] = []
    /// The in-flight broker apply, so a rapid toggle chains rather than races (see
    /// `scheduleBrokerApply`). Non-private for the `AppModel+DeepLink` extension.
    var brokerApplyTask: Task<Void, Never>?
    private var didFinishInit = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        measureSizes = defaults.bool(forKey: PreferenceKeys.measureSizes)
        installOverridePath = defaults.string(forKey: PreferenceKeys.installDirectoryOverride) ?? ""
        profilesOverridePath = defaults.string(forKey: PreferenceKeys.profilesDirectoryOverride) ?? ""
        badgeStyle = Self.loadBadgeStyle(from: defaults)
        // On by default: `object` distinguishes "never set" (→ true) from an explicit off.
        deepLinkBrokerEnabled = defaults.object(forKey: PreferenceKeys.deepLinkBrokerEnabled) as? Bool ?? true
        usageHistory = UsageHistoryStore(path: Self.usageDatabaseURL().path)
        usageTrackingEnabled = defaults.object(forKey: PreferenceKeys.usageTrackingEnabled) as? Bool ?? true
        // `object` distinguishes unset (→ 30) from an explicit 0 (manual-only).
        let pollMinutes = defaults.object(forKey: PreferenceKeys.usagePollIntervalMinutes) as? Int
        usagePollIntervalMinutes = pollMinutes ?? UsageService.defaultPollMinutes
        usageAdaptiveEnabled = defaults.object(forKey: PreferenceKeys.usageAdaptiveEnabled) as? Bool ?? true
        usageNotificationsEnabled = defaults
            .object(forKey: PreferenceKeys.usageNotificationsEnabled) as? Bool ?? true
        locate()
        didFinishInit = true
        // Wire the AppKit deep-link sink and run the launch tasks. Both are deferred to the
        // main runloop (not done inline in `init`) because `NSApp` isn't fully set up yet, and
        // window-independently — a login/menu-bar-only launch shows no window (so
        // `RootView.task` may never run) yet must still grab the handler.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            wireDeepLinkHandler()
            Task { @MainActor in await self.performLaunchTasks() }
        }
    }

    /// One-shot guard for `performLaunchTasks` (owned by the `AppModel+DeepLink` extension).
    var didPerformLaunch = false

    private static func loadBadgeStyle(from defaults: UserDefaults) -> BadgeStyle {
        guard let data = defaults.data(forKey: PreferenceKeys.badgeStyle),
              let style = try? JSONDecoder().decode(BadgeStyle.self, from: data)
        else { return .default }
        return style
    }

    private func persistBadgeStyle() {
        guard let data = try? JSONEncoder().encode(badgeStyle) else { return }
        defaults.set(data, forKey: PreferenceKeys.badgeStyle)
    }

    // MARK: - Derived config

    var effectiveInstallDirectory: URL? {
        if !installOverridePath.isEmpty { return URL(fileURLWithPath: installOverridePath) }
        return realClaude?.installDirectory
    }

    var effectiveProfilesDirectory: URL {
        if !profilesOverridePath.isEmpty { return URL(fileURLWithPath: profilesOverridePath) }
        return MetadataStore.defaultDirectory().appendingPathComponent("Profiles", isDirectory: true)
    }

    func locate() {
        do {
            let real = try RealClaudeLocator().locate()
            realClaude = real
            realClaudeVersion = real.version()
            locateError = nil
        } catch {
            realClaude = nil
            realClaudeVersion = nil
            primaryProfile = nil
            // A vanished Claude has no staged update to apply; clear it so the banner doesn't
            // outlive the app it refers to (refresh, its only other writer, bails while nil).
            stagedUpdate = nil
            locateError = Self.describe(error)
        }
    }

    /// User-driven re-detect (the missing-Claude banner's Retry and Settings' Re-detect):
    /// locate synchronously, then — only if Claude was found — refresh so it repopulates the
    /// profile list (the default-profile row included) without waiting for the next poll.
    /// Skipping refresh when locate still fails avoids `perform` surfacing a redundant
    /// "Claude not found" alert on top of the banner that already says so.
    func relocate() async {
        locate()
        guard realClaude != nil else { return }
        await refresh()
        // A first launch with Claude missing skipped the broker apply (`perform` bailed, so
        // `reconcileAllManagedConfigs` never ran and the `claude://` handler was never grabbed).
        // Re-run it now that Claude is found, so clone overlays and the handler are consistent
        // without needing an app restart or a manual broker toggle. Idempotent.
        await applyDeepLinkBroker()
    }

    func currentConfiguration() -> ProfileStoreConfiguration? {
        guard let real = realClaude else { return nil }
        var config = ProfileStoreConfiguration.makeDefault(realClaude: real)
        if let installOverride = effectiveInstallDirectory { config.installDirectory = installOverride }
        config.defaultProfilesDirectory = effectiveProfilesDirectory
        config.badgeStyle = badgeStyle
        return config
    }

    // MARK: - Reads

    func refresh() async {
        let sizes = measureSizes
        // One process sweep yields both the launcher list and the default-profile status.
        guard let snapshot = await perform({ store in store.snapshot(measuringSizes: sizes) }) else { return }
        profiles = snapshot.profiles
        primaryProfile = snapshot.primaryProfile
        // Probe the staged update directly (not via `snapshot`, which is empty of clones when
        // there are none — the default profile can still have one staged).
        stagedUpdate = await perform { store in store.stagedUpdate() }.flatMap(\.self)
        await notifyClaudeUpdatesIfNeeded()
        await notifyStagedUpdateIfNeeded()
        // Detached: the editor's Save awaits `refresh()`, and a usage pass issues per-account
        // HTTP with a 5s timeout each — awaiting it froze the sheet for tens of seconds offline.
        Task { await refreshUsageIfBindingsChanged() }
    }

    func runDoctor() async {
        guard var result = await perform({ store in store.doctor() }) else { return }
        if let usage = usageDoctorDiagnostic() { result.append(usage) }
        diagnostics = result
    }

    func refreshRunningInstances() async {
        guard let result = await perform({ store in store.runningInstances() }) else { return }
        runningInstances = result
    }

    // MARK: - Mutations

    /// Create a launcher. Throws so the editor can present the failure *itself* (its
    /// sheet covers the window-level alert, so a swallowed error would be invisible
    /// until the editor is dismissed).
    func addProfile(_ request: AddProfileRequest) async throws {
        _ = try await performThrowing { store in try store.add(request) }
        await refresh()
    }

    /// Apply edits. Throws for the same reason as `addProfile`.
    func updateProfile(original: Profile, to updated: Profile) async throws {
        _ = try await performThrowing { store in try store.update(original: original, to: updated) }
        await refresh()
    }

    func removeProfile(_ profile: Profile, purgeProfile: Bool) async {
        _ = await perform { store in try store.remove(profile, purgeProfile: purgeProfile) }
        await refresh()
    }

    /// Bring the app that owns `pid` to the front, returning whether it was activated.
    /// `false` means no running app owns `pid` (just quit / not yet registered) or the
    /// activation request was refused — either way the caller falls back to a launch.
    /// Non-private and shared by the managed-profile and primary-profile focus paths.
    ///
    /// `.activateAllWindows` raises every window of the target, not just main/key — the
    /// robust choice when focusing another app from our own menu-bar extra. macOS 14
    /// retired forceful cross-app activation (`.activateIgnoringOtherApps` is a deprecated
    /// no-op), so activation is cooperative and best-effort: the user's click supplies the
    /// context the system needs to honor it.
    func activateApp(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        // Propagate the result: `activate` returns false if the app quit between the lookup
        // and here (or can't be activated), so the caller relaunches instead of assuming a
        // window it never raised.
        return app.activate(options: [.activateAllWindows])
    }

    func stop(_ profile: Profile, force: Bool) async {
        let outcome = await perform { store in await store.stop(profile, force: force) }
        if case let .stillRunning(pid)? = outcome {
            currentError =
                AppError(message: "\(profile.displayName) is still running (pid \(pid)). Try Force Stop.")
        }
        await refresh()
    }

    /// Rebuild one launcher from the current wrapper format (script + Info.plist +
    /// icon). Used both to clear a stale launcher and to force a fresh regenerate.
    func rebuild(_ profile: Profile) async {
        _ = await perform { store in try store.rebuild(profile) }
        await refresh()
    }

    /// Rebuild every launcher. Running ones are skipped and per-launcher failures are
    /// collected by the core (the batch never aborts); surface either as a non-fatal
    /// notice via the same channel `stop` uses for its running warning.
    func rebuildAll() async {
        guard let result = await perform({ store in try store.rebuildAll() }) else { return }
        if let notice = rebuildAllNotice(for: result) {
            currentError = AppError(message: notice)
        }
        await refresh()
    }

    /// A non-fatal summary when a batch rebuild didn't touch every launcher, or `nil`
    /// when all were rebuilt cleanly.
    private func rebuildAllNotice(for result: RebuildAllResult) -> String? {
        var parts: [String] = []
        if !result.skippedRunning.isEmpty {
            let c = result.skippedRunning.count
            let names = result.skippedRunning.map(\.displayName).joined(separator: ", ")
            parts.append(
                "Skipped \(c) running launcher\(c == 1 ? "" : "s") (\(names)) — stop them, then rebuild."
            )
        }
        if !result.failed.isEmpty {
            let c = result.failed.count
            let names = result.failed.map(\.profile.displayName).joined(separator: ", ")
            parts.append("Failed to rebuild \(c) launcher\(c == 1 ? "" : "s"): \(names).")
            // Carry the reason through, not just the names: a signing failure leaves the
            // launcher unable to start, and without this the user has nothing to act on.
            // Distinct reasons only — a shared cause (the usual case) prints once.
            let reasons = Set(result.failed.map(\.reason)).sorted()
            parts.append(reasons.joined(separator: " "))
        }
        guard !parts.isEmpty else { return nil }
        let n = result.rebuilt.count
        return "Rebuilt \(n) launcher\(n == 1 ? "" : "s"). " + parts.joined(separator: " ")
    }

    private struct LocateResult {
        let real: RealClaude?
        let version: String?
        let error: String?
    }

    /// Off-main `locate` for the background monitor: the LaunchServices lookup and
    /// Info.plist reads run on a detached task; only the published assignment happens
    /// back on the main actor. `locate()` stays synchronous for one-shot, user-driven
    /// calls (init, Retry, Re-detect) where the main-thread cost is fine.
    func locateOffMain() async {
        let located = await Task.detached { () -> LocateResult in
            do {
                let real = try RealClaudeLocator().locate()
                return LocateResult(real: real, version: real.version(), error: nil)
            } catch {
                return LocateResult(real: nil, version: nil, error: Self.describe(error))
            }
        }.value
        realClaude = located.real
        realClaudeVersion = located.version
        // A vanished Claude leaves no default profile and no staged update to apply;
        // `reconcile` returns before `refresh` could recompute them, so clear the stale
        // primary row and staged-update banner here.
        if located.real == nil {
            primaryProfile = nil
            stagedUpdate = nil
        }
        locateError = located.error
    }
}

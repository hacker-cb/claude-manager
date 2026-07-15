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
    @Published private(set) var realClaude: RealClaude?
    @Published private(set) var realClaudeVersion: String?
    @Published var locateError: String?
    @Published private(set) var isBusy = false
    @Published var currentError: AppError?

    /// Number of in-flight operations; `isBusy` tracks it. A shared Bool would let
    /// a fast operation clear the spinner while a slow one (e.g. a ~10s stop) runs.
    private var inflight = 0 {
        didSet { isBusy = inflight > 0 }
    }

    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var runningInstances: [ClaudeInstance] = []

    /// A Claude update ShipIt has staged but not applied (any open account blocks the
    /// swap) — drives the "Apply update to all accounts" affordance. `nil` when none.
    @Published private(set) var stagedUpdate: StagedUpdate?
    /// True while a coordinated apply is in flight, so the UI disables re-triggering and
    /// the background monitor pauses (a relaunch mid-swap would trip ShipIt's Gate 2).
    @Published private(set) var isApplyingStagedUpdate = false
    /// Staged versions already surfaced as a notification, so it nags once per version.
    var notifiedStagedUpdate: Set<String> = []

    /// Flip the apply-in-flight flag. A method because the property is `private(set)`; the
    /// `AppModel+StagedUpdate` extension (another file) drives it around the apply.
    func setApplyingStagedUpdate(_ value: Bool) {
        isApplyingStagedUpdate = value
    }

    /// Update keys ("`appPath@targetVersion`") already surfaced as a notification, so
    /// a pending update nags once — not on every refresh. A skew that resolves (the
    /// instance was restarted) drops out, so a later update notifies afresh.
    /// Non-private for the `AppModel+StagedUpdate` extension, which owns the update
    /// notifications.
    var notifiedClaudeUpdates: Set<String> = []
    private var monitorTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    /// Serializes `openReal`: `@MainActor` makes its check-and-set atomic, so two
    /// overlapping runs can't both `open -n` a duplicate default. See `openReal`.
    /// Non-private so the `AppModel+PrimaryAccount` extension (another file) can reach it.
    var isOpeningReal = false

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

    /// Whether the `claude://` deep-link broker owns the handler (opt-in). Changing it
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
        deepLinkBrokerEnabled = defaults.bool(forKey: PreferenceKeys.deepLinkBrokerEnabled)
        locate()
        didFinishInit = true
        // Wire the AppKit deep-link sink once the delegate is installed (next runloop):
        // a link can launch the app menu-bar-only, before any window/scene appears.
        DispatchQueue.main.async { [weak self] in
            (NSApp.delegate as? AppDelegate)?.deepLinkHandler = { [weak self] urls in
                self?.handleDeepLinks(urls)
            }
        }
    }

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
            locateError = Self.describe(error)
        }
    }

    private func currentConfiguration() -> ProfileStoreConfiguration? {
        guard let real = realClaude else { return nil }
        var config = ProfileStoreConfiguration.makeDefault(realClaude: real)
        if let installOverride = effectiveInstallDirectory { config.installDirectory = installOverride }
        config.defaultProfilesDirectory = effectiveProfilesDirectory
        config.badgeStyle = badgeStyle
        config.deepLinkBrokerEnabled = deepLinkBrokerEnabled
        return config
    }

    /// Build a store for synchronous, non-blocking calls (e.g. `draft`).
    func makeStore() -> ProfileStore? {
        guard let real = realClaude, let config = currentConfiguration() else { return nil }
        return ProfileStore(realClaude: real, configuration: config)
    }

    // MARK: - Reads

    func refresh() async {
        let sizes = measureSizes
        guard let listed = await perform({ store in store.list(measuringSizes: sizes) }) else { return }
        profiles = listed
        // Probe the staged update directly (not via `listed`, which is empty when there
        // are no clones — the default account can still have one staged).
        stagedUpdate = await perform { store in store.stagedUpdate() }.flatMap(\.self)
        await notifyClaudeUpdatesIfNeeded()
        await notifyStagedUpdateIfNeeded()
    }

    func runDoctor() async {
        guard let result = await perform({ store in store.doctor() }) else { return }
        diagnostics = result
    }

    func refreshRunningInstances() async {
        guard let result = await perform({ store in store.runningInstances() }) else { return }
        runningInstances = result
    }

    func draft(
        name: String,
        label: String? = nil,
        color: BadgeColor? = nil,
        displayName: String? = nil,
        bundleID: String? = nil,
        profilePath: String? = nil
    ) -> Profile? {
        makeStore()?.draft(
            name: name, label: label, color: color,
            displayName: displayName, bundleID: bundleID, profilePath: profilePath
        )
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

    func open(_ profile: Profile) async {
        // A running profile only needs its window raised — activate it by pid instead of
        // relaunching the launcher app, which would flash a transient Dock icon (it
        // starts, self-activates via `activate_existing`, and exits at once). Fall back to
        // a launch (shlock-guarded) when nothing owns the probed pid. Refresh either way,
        // so a list that was stale-as-stopped reflects the profile we just proved running.
        if let pid = await runningPID(for: profile), activateApp(pid: pid) {
            await refresh()
            return
        }
        _ = await perform { store in try store.open(profile) }
        await refresh()
    }

    /// Running pid for a managed profile, or `nil`. `nil` means "not running" — and a
    /// `perform` probe failure flattens to the same `nil`, so the two are indistinguishable
    /// here; the caller treats `nil` as "launch it", the safe reading either way.
    private func runningPID(for profile: Profile) async -> Int32? {
        await perform { store in store.runningPID(for: profile) }.flatMap(\.self)
    }

    /// Bring the app that owns `pid` to the front, returning whether it was activated.
    /// `false` means no running app owns `pid` (just quit / not yet registered) or the
    /// activation request was refused — either way the caller falls back to a launch.
    /// Non-private and shared by the managed-profile and primary-account focus paths.
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

    /// Quit the running instance and relaunch it — how a live instance moves onto a
    /// freshly-updated Claude (its version is fixed at launch, so only a relaunch
    /// picks up an in-place app update). Graceful stop first; if it won't exit, leave
    /// it running and surface the same notice `stop` does rather than force-killing.
    func restart(_ profile: Profile) async {
        let outcome = await perform { store in await store.stop(profile, force: false) }
        switch outcome {
        case .stopped?, .notRunning?:
            _ = await perform { store in try store.open(profile) }
        case let .stillRunning(pid)?:
            currentError = AppError(
                message: "\(profile.displayName) is still running (pid \(pid)). Try Force Stop, then Open."
            )
        case nil:
            break // perform already surfaced the failure
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
            let names = result.failed.map(\.displayName).joined(separator: ", ")
            parts.append("Failed to rebuild \(c) launcher\(c == 1 ? "" : "s"): \(names).")
        }
        guard !parts.isEmpty else { return nil }
        let n = result.rebuilt.count
        return "Rebuilt \(n) launcher\(n == 1 ? "" : "s"). " + parts.joined(separator: " ")
    }

    // MARK: - Finder helpers

    func revealProfileData(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileURL])
    }

    func revealLauncher(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.appURL])
    }

    // MARK: - Claude update monitoring

    /// Start watching for the real Claude.app updating out from under running
    /// instances: refresh when the user returns to the manager, and poll (while the app
    /// is frontmost) so a background update surfaces even with the window open.
    /// Idempotent — safe to call from `.task` on every appearance.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A cheap guaranteed re-check on top of the Darwin observer: if Claude
                // grabbed the handler while we were away, take it back.
                self.deepLinkService.reassertIfNeeded()
                // Skip the rescan while a staged-update apply is in flight (same reason as
                // the poll loop: avoid a relaunch during ShipIt's swap window).
                guard !self.isApplyingStagedUpdate else { return }
                await self.reconcile()
            }
        }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                // Poll only while frontmost — a backgrounded menu-bar app catches up
                // via didBecomeActive instead of spawning `ps` every minute forever.
                // @MainActor so NSApp.isActive is read on the main thread. Skip while a
                // staged-update apply is in flight: re-probing is fine, but a relaunch it
                // could trigger during the swap window would trip ShipIt's Gate 2.
                if NSApp.isActive, !isApplyingStagedUpdate { await reconcile() }
            }
        }
    }

    /// Cancel the poll and drop the activation observer. The root model normally lives
    /// for the process, but explicit teardown keeps `startMonitoring` restartable.
    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Re-read the on-disk Claude version and rescan running state, so a version skew
    /// (its badge, banner, and notification) appears without a manual refresh. The
    /// locate runs off the main actor (LaunchServices + plist reads block); a missing
    /// Claude is left to the persistent banner rather than re-raising the alert.
    private func reconcile() async {
        await locateOffMain()
        guard realClaude != nil else { return }
        await refresh()
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
    private func locateOffMain() async {
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
        locateError = located.error
    }

    // MARK: - Plumbing

    /// Run a store operation off the main actor — it may block or suspend (e.g. the
    /// async `stop`) — surfacing errors as an alert. Returns `nil` on failure.
    /// Non-private so type extensions in other files (e.g. `AppModel+PrimaryAccount`)
    /// share the one dispatch path.
    func perform<T: Sendable>(
        _ body: @Sendable @escaping (ProfileStore) async throws -> T
    ) async -> T? {
        guard let real = realClaude, let config = currentConfiguration() else {
            currentError = AppError(message: locateError ?? "Real Claude.app was not found.")
            return nil
        }
        inflight += 1
        defer { inflight -= 1 }
        do {
            return try await Task.detached {
                let store = ProfileStore(realClaude: real, configuration: config)
                return try await body(store)
            }.value
        } catch {
            currentError = AppError(error)
            return nil
        }
    }

    /// Like `perform`, but re-throws instead of routing the error to `currentError`.
    /// The caller (the editor) presents the failure in its own sheet-level alert.
    private func performThrowing<T: Sendable>(
        _ body: @Sendable @escaping (ProfileStore) async throws -> T
    ) async throws -> T {
        guard let real = realClaude, let config = currentConfiguration() else {
            // Preserve the specific locate reason (mirrors `perform`'s alert) rather
            // than a generic realClaudeNotFound, since the editor shows this directly.
            throw MessageError(message: locateError ?? "Real Claude.app was not found.")
        }
        inflight += 1
        defer { inflight -= 1 }
        return try await Task.detached {
            let store = ProfileStore(realClaude: real, configuration: config)
            return try await body(store)
        }.value
    }

    private nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

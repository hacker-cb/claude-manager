import AppKit
import ClaudeManagerCore
import SwiftUI

/// A user-facing error wrapped for `.alert(item:)`.
struct AppError: Identifiable {
    let id = UUID()
    let message: String
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

    @Published var measureSizes: Bool {
        didSet { defaults.set(measureSizes, forKey: PreferenceKeys.measureSizes) }
    }

    @Published var installOverridePath: String {
        didSet { defaults.set(installOverridePath, forKey: PreferenceKeys.installDirectoryOverride) }
    }

    @Published var profilesOverridePath: String {
        didSet { defaults.set(profilesOverridePath, forKey: PreferenceKeys.profilesDirectoryOverride) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        measureSizes = defaults.bool(forKey: PreferenceKeys.measureSizes)
        installOverridePath = defaults.string(forKey: PreferenceKeys.installDirectoryOverride) ?? ""
        profilesOverridePath = defaults.string(forKey: PreferenceKeys.profilesDirectoryOverride) ?? ""
        locate()
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

    /// The real Claude app icon, for badge previews.
    var realAppIcon: NSImage? {
        guard let real = realClaude else { return nil }
        return NSWorkspace.shared.icon(forFile: real.appURL.path)
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

    @discardableResult
    func addProfile(_ request: AddProfileRequest) async -> Bool {
        let result = await perform { store in try store.add(request) }
        await refresh()
        return result != nil
    }

    @discardableResult
    func updateProfile(original: Profile, to updated: Profile) async -> Bool {
        let result = await perform { store in try store.update(original: original, to: updated) }
        await refresh()
        return result != nil
    }

    func removeProfile(_ profile: Profile, purgeProfile: Bool) async {
        _ = await perform { store in try store.remove(profile, purgeProfile: purgeProfile) }
        await refresh()
    }

    func open(_ profile: Profile) async {
        _ = await perform { store in try store.open(profile) }
        await refresh()
    }

    func stop(_ profile: Profile, force: Bool) async {
        let outcome = await perform { store in await store.stop(profile, force: force) }
        if case let .stillRunning(pid)? = outcome {
            currentError =
                AppError(message: "\(profile.displayName) is still running (pid \(pid)). Try Force Stop.")
        }
        await refresh()
    }

    func regenerateIcon(_ profile: Profile) async {
        _ = await perform { store in try store.regenerateIcon(for: profile) }
    }

    func regenerateAllIcons() async {
        _ = await perform { store in try store.regenerateAllIcons() }
    }

    // MARK: - Finder helpers

    func revealProfileData(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileURL])
    }

    func revealLauncher(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.appURL])
    }

    // MARK: - Plumbing

    /// Run a store operation off the main actor — it may block or suspend (e.g. the
    /// async `stop`) — surfacing errors as an alert. Returns `nil` on failure.
    private func perform<T: Sendable>(
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
            currentError = AppError(message: Self.describe(error))
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import AppKit
import ClaudeManagerCore
import SwiftUI

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        measureSizes = defaults.bool(forKey: PreferenceKeys.measureSizes)
        installOverridePath = defaults.string(forKey: PreferenceKeys.installDirectoryOverride) ?? ""
        profilesOverridePath = defaults.string(forKey: PreferenceKeys.profilesDirectoryOverride) ?? ""
        badgeStyle = Self.loadBadgeStyle(from: defaults)
        locate()
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
        return config
    }

    /// Render a WYSIWYG badge preview using the authoritative core renderer (same path
    /// the `.icns` uses). `nil` if the real app is absent. The heavy CoreGraphics work
    /// runs off the main actor; the `NSImage` is built back on the main actor.
    func badgePreview(
        label: String,
        color: BadgeColor,
        style: BadgeStyle,
        pixels: Int = 128
    ) async -> NSImage? {
        guard let iconURL = realClaude?.iconURL else { return nil }
        // Debounce in the caller's cancellable `.task`: a superseded preview (rapid
        // slider scrubbing) cancels this sleep before the render is even started.
        try? await Task.sleep(for: .milliseconds(80))
        if Task.isCancelled { return nil }
        let png = await Task.detached(priority: .userInitiated) {
            Self.renderBadgePNG(iconURL: iconURL, label: label, color: color, style: style, pixels: pixels)
        }.value
        // Back on the main actor here — build the AppKit image on the main thread.
        return png.flatMap(NSImage.init(data:))
    }

    /// Pure, actor-independent PNG render used by `badgePreview` off the main actor.
    private nonisolated static func renderBadgePNG(
        iconURL: URL,
        label: String,
        color: BadgeColor,
        style: BadgeStyle,
        pixels: Int
    ) -> Data? {
        guard let base = try? RealIconExtractor.loadBaseIcon(from: iconURL) else { return nil }
        return try? BadgeRenderer().renderPreviewPNG(
            base: base, label: label, color: color.rgba, style: style, pixels: pixels
        )
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

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

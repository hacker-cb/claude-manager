import AppKit
import Combine
import Sparkle
import SwiftUI

/// A "Check for Updates…" button wired to Sparkle's updater. The button disables
/// itself while a check can't run (e.g. one is already in flight), following the
/// canonical Sparkle-SwiftUI pattern — the SwiftUI layer can't bind directly to
/// `SPUUpdater.canCheckForUpdates` (a plain KVO property), so a tiny observable
/// view model republishes it.
///
/// The same view backs both the app menu's `CommandGroup(after: .appInfo)` item and
/// the `MenuBarExtra` menu; both share the one `SPUUpdater` from the app-scoped
/// `SPUStandardUpdaterController` (two updaters would race the same schedule).
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: UpdaterReadiness
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: UpdaterReadiness(updater: updater))
    }

    var body: some View {
        // Named for its subject: the item directly above it checks *Claude's* updates, and
        // two neighbours both reading "Check for Updates…" would be a coin toss.
        Button("Check for Claude Manager Updates…") {
            // Bring the app forward so Sparkle's modal update dialog can't open behind other
            // windows — the check often fires from the menu-bar extra while another app is
            // frontmost, where cooperative `NSApp.activate()` isn't guaranteed to foreground us.
            // Forceful is intentional and warning-free (Apple softened the deprecation) — see #31.
            NSApp.activate(ignoringOtherApps: true)
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Republishes `SPUUpdater.canCheckForUpdates` (KVO) as an observable property so a
/// SwiftUI `Button` can enable/disable on it. `@MainActor` because `SPUUpdater`'s
/// properties are main-actor isolated under Swift 6 (forming the KVO key path requires
/// it); the view models are only ever constructed from main-actor SwiftUI bodies.
///
/// Shared with the toolbar's update control (`UpdateStatusButton`), which opens the same
/// modal flow and is dead in the same states — `checkForUpdates()` returns without a word
/// while a session is in progress, so a button that stays enabled through one is a press
/// that does nothing.
@MainActor
final class UpdaterReadiness: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The Settings "Updates" toggles. Binds straight to Sparkle's own persisted state
/// (`automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates`) — Sparkle is the
/// single source of truth for these, so there is deliberately no parallel UserDefaults /
/// `PreferenceKeys` entry that could drift. Automatic *download* is gated on automatic
/// *check* because Sparkle can't download without first checking.
struct UpdaterSettingsView: View {
    @StateObject private var model: UpdaterSettingsModel

    init(updater: SPUUpdater) {
        _model = StateObject(wrappedValue: UpdaterSettingsModel(updater: updater))
    }

    var body: some View {
        Toggle("Automatically check for updates", isOn: $model.automaticallyChecksForUpdates)
        Toggle("Automatically download updates", isOn: $model.automaticallyDownloadsUpdates)
            .disabled(!model.automaticallyChecksForUpdates)
    }
}

/// Mirrors Sparkle's automatic-update flags into published properties and writes any
/// change back to the updater. `@MainActor` for the same reason as `UpdaterReadiness`.
///
/// **It follows Sparkle rather than sampling it once.** `automaticallyDownloadsUpdates` is not
/// a plain stored flag: Sparkle recomputes it whenever automatic *checks* are toggled, because
/// a download cannot happen without a check (`allowsAutomaticUpdates`) — and with the download
/// default now coming from the Info.plist, turning checks back on flips it to `true`
/// underneath a toggle that was showing `false`. A snapshot taken at init would then say
/// "off" while Sparkle fetches releases. The KVO publishers keep both rows honest.
@MainActor
private final class UpdaterSettingsModel: ObservableObject {
    private let updater: SPUUpdater

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { write(automaticallyChecksForUpdates, to: \.automaticallyChecksForUpdates) }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { write(automaticallyDownloadsUpdates, to: \.automaticallyDownloadsUpdates) }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
    }

    /// Write back only a value Sparkle does not already hold.
    ///
    /// Without the guard the two directions feed each other: the publisher assigns, `didSet`
    /// writes, Sparkle posts the change, the publisher assigns again. Sparkle's own setters
    /// send `willChange`/`didChange` unconditionally, so the loop does not settle on its own.
    private func write(_ value: Bool, to keyPath: ReferenceWritableKeyPath<SPUUpdater, Bool>) {
        guard updater[keyPath: keyPath] != value else { return }
        updater[keyPath: keyPath] = value
    }
}

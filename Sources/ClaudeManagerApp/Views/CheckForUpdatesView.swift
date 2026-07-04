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
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            // Bring the app forward so Sparkle's modal update dialog can't open behind
            // other windows — the check is often triggered from the menu-bar extra with
            // no window focused.
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
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
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
/// change back to the updater. Reads seed from Sparkle on init (property observers do
/// not fire during initialization, so no write-back loop). `@MainActor` for the same
/// reason as `CheckForUpdatesViewModel`.
@MainActor
private final class UpdaterSettingsModel: ObservableObject {
    private let updater: SPUUpdater

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
}

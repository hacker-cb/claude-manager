import Sparkle
import SwiftUI

@main
struct ClaudeManagerApp: App {
    @StateObject private var model = AppModel()

    /// One updater for the whole app, shared by the menu command, the MenuBarExtra item,
    /// and the Settings toggles — a second `SPUStandardUpdaterController` would race the
    /// same schedule and defaults. Started only for real (released) builds: a locally
    /// built app carries the `CFBundleVersion` placeholder `1`, which Sparkle would read
    /// as older than every published release and nag a developer to overwrite their own
    /// working build. `startingUpdater: false` leaves the updater dormant (checks
    /// disabled) for those.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: Self.updatesEnabled,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Claude Manager", id: WindowID.main) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Claude Manager", systemImage: "square.stack.3d.up.fill") {
            MenuBarContent(updater: updaterController.updater)
                .environmentObject(model)
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(model)
        }
    }

    /// Whether Sparkle should run in this build. False for local/dev builds, which carry
    /// the `CURRENT_PROJECT_VERSION` placeholder `1` (CI injects the run number for a
    /// real release — see scripts/build-app.sh).
    private static var updatesEnabled: Bool {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) != "1"
    }
}

enum WindowID {
    static let main = "main"
}

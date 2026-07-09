import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

@main
struct ClaudeManagerApp: App {
    /// Keeps the app resident in the menu bar after the window closes and reopens it on
    /// a Dock-icon click — see `AppDelegate`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    /// "Launch at login" state, backed by the system login-item database.
    @StateObject private var launchAtLogin = LaunchAtLogin()

    /// "Menu bar only" (Dock-icon) state and activation-policy control.
    @StateObject private var menuBarChrome = MenuBarChrome()

    /// One updater for the whole app, shared by the menu command, the MenuBarExtra item,
    /// and the Settings toggles — a second `SPUStandardUpdaterController` would race the
    /// same schedule and defaults. Started only for distributed (released) builds: a
    /// locally built app carries the `MARKETING_VERSION` placeholder `0.0.0`, which Sparkle
    /// would read as older than every published release and nag a developer to overwrite
    /// their own working build. `startingUpdater: false` leaves the updater dormant (checks
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
                .modifier(MainWindowLaunchBinder(delegate: appDelegate, chrome: menuBarChrome))
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
                .environmentObject(launchAtLogin)
                .environmentObject(menuBarChrome)
        }
    }

    /// Whether Sparkle should run in this build. False for local/dev builds, which carry
    /// the `MARKETING_VERSION` placeholder `0.0.0` (CI injects the tag version for a real
    /// release — see scripts/build-app.sh). Keyed on the marketing version rather than
    /// `CFBundleVersion` because the build number is the CI run number, which is `1` on a
    /// repo's first release run and must not disable the inaugural release's updater.
    private static var updatesEnabled: Bool {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? CoreConstants.devMarketingVersion
        return CoreConstants.isDistributionBuild(marketingVersion: marketingVersion)
    }
}

enum WindowID {
    static let main = "main"
}

/// Wires the main `Window` scene into the app's AppKit-level lifecycle, both hooks that
/// need a live view (SwiftUI window actions can only be read inside one):
///
/// - Injects a SwiftUI `openWindow` closure into the AppKit delegate so a Dock-icon
///   reopen (`AppDelegate.applicationShouldHandleReopen`) can bring the window back. The
///   captured action stays valid for the process, so it still reopens after a close.
/// - Quiets a **menu-bar-only launch** by dismissing the window SwiftUI auto-opened.
///   Doing this in `onAppear` (rather than guessing a runloop tick in the delegate) fires
///   deterministically when the window appears, so it can't miss a late-materialized
///   window; `shouldDismissLaunchWindow` makes it one-shot, so a window the user opens
///   later is never auto-closed. A brief launch flash is the residual macOS-14 limitation.
private struct MainWindowLaunchBinder: ViewModifier {
    let delegate: AppDelegate
    let chrome: MenuBarChrome
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.reopenMainWindow = {
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
            if chrome.shouldDismissLaunchWindow() {
                dismissWindow(id: WindowID.main)
            }
        }
    }
}

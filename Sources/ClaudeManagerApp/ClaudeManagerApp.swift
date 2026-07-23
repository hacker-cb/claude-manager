import AppKit
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

    /// One updater for the whole app, shared by the menu command, the MenuBarExtra item,
    /// and the Settings toggles — a second `SPUStandardUpdaterController` would race the
    /// same schedule and defaults. Started only for distributed (released) builds: a
    /// locally built app carries the `MARKETING_VERSION` placeholder `0.0.0`, which Sparkle
    /// would read as older than every published release and nag a developer to overwrite
    /// their own working build. `startingUpdater: false` leaves the updater dormant (checks
    /// disabled) for those.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: AppBuild.isDistribution,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Claude Manager", id: WindowID.main) {
            RootView()
                .environmentObject(model)
                .environmentObject(launchAtLogin)
                .frame(minWidth: 760, minHeight: 480)
                .modifier(MainWindowLaunchBinder(delegate: appDelegate))
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

        MenuBarExtra {
            MenuBarContent(updater: updaterController.updater)
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(model)
                .environmentObject(launchAtLogin)
                .modifier(DockFollowsWindow(delegate: appDelegate))
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Wires the main `Window` scene into the app's AppKit-level lifecycle — hooks that need a
/// live view, since SwiftUI window actions (`openWindow`, `dismissWindow`) can only be read
/// inside one:
///
/// - Injects an `openWindow` closure into the delegate so a Dock-icon reopen
///   (`AppDelegate.applicationShouldHandleReopen`) can bring the window back.
/// - Drives the **Dock icon from the window**: `onAppear` marks the window open
///   (`windowDidAppear`) and `onDisappear` re-syncs the policy (`windowDidDisappear`).
/// - Quiets a **login launch**: on the very first appearance the delegate says whether to
///   dismiss the auto-opened window (`shouldDismissInitialWindow`), keeping a login start
///   menu-bar-only. Done in `onAppear` (not a guessed runloop tick) so it can't miss a late
///   window; one-shot, so a window the user opens later is untouched. A brief launch flash
///   is the residual macOS-14 limitation (no declarative initial-window suppression).
private struct MainWindowLaunchBinder: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                delegate.reopenMainWindow = {
                    openWindow(id: WindowID.main)
                    NSApp.activate()
                }
                if delegate.shouldDismissInitialWindow() {
                    dismissWindow(id: WindowID.main)
                } else {
                    delegate.windowDidAppear()
                }
            }
            .onDisappear { delegate.windowDidDisappear() }
    }
}

/// Feeds a secondary scene (Settings) into the delegate's Dock-icon logic so the icon stays
/// shown while it is open and the app re-syncs when it closes. The main window uses
/// `MainWindowLaunchBinder` (which also handles reopen + the login dismissal); this is the
/// plain appear/disappear version for scenes that need nothing else.
private struct DockFollowsWindow: ViewModifier {
    let delegate: AppDelegate

    func body(content: Content) -> some View {
        content
            .onAppear { delegate.windowDidAppear() }
            .onDisappear { delegate.windowDidDisappear() }
    }
}

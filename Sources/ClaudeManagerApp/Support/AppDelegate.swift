import AppKit

/// AppKit delegate wired in via `NSApplicationDelegateAdaptor`. It owns the app lifecycle
/// and Dock-icon (activation-policy) behavior that SwiftUI's `Window` scene doesn't expose
/// declaratively:
///
/// - **Stay resident in the menu bar** after the last window closes, instead of quitting
///   (`applicationShouldTerminateAfterLastWindowClosed` → false). Explicit quit
///   (⌘Q / "Quit Claude Manager", which call `NSApp.terminate`) still terminates.
/// - **Reopen the main window** on a Dock-icon click while no window is visible, via the
///   injected `reopenMainWindow` (AppKit can't invoke SwiftUI's window actions directly).
/// - **The Dock icon follows the window.** The app is `.regular` (Dock icon) only while its
///   window is open and `.accessory` (menu-bar-only) when closed — driven by the scene's
///   appear/disappear (`MainWindowLaunchBinder` calls `windowDidOpen` / `windowDidClose`).
///   A launch triggered at login starts menu-bar-only and dismisses its auto-opened
///   window; a manual launch keeps the window (see `applicationDidFinishLaunching` and
///   `shouldDismissInitialWindow`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reopens the main window. Set by the `Window` scene once its content appears and
    /// stays valid for the life of the process (the scene lives in `body` even while its
    /// window is closed). `nil` only before that first appearance, a harmless no-op.
    var reopenMainWindow: (() -> Void)?

    /// Whether this process was launched automatically at login (rather than opened by the
    /// user). macOS exposes no documented SMAppService signal for this, so we fall back to
    /// the legacy `NSApplication.launchIsDefaultUserInfoKey` (`false` ⇒ not a user launch).
    /// Best-effort: if some macOS build doesn't set it for the login-item launch, the
    /// launch is treated as manual and the window shows.
    private var launchedAtLogin = false
    /// Guards the one-shot handling of the auto-opened launch window.
    private var initialWindowHandled = false

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenMainWindow?() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == false
        // Start menu-bar-only for a login launch; a manual launch shows its window (and so
        // the Dock icon). The window-driven policy keeps this in sync from there on.
        setDockIconVisible(!launchedAtLogin)
    }

    /// Whether the initial (auto-opened) launch window should be dismissed to keep a login
    /// launch quiet. One-shot: returns `true` only for the very first window, and only at
    /// login. Every later window (including one the user opens) returns `false`.
    func shouldDismissInitialWindow() -> Bool {
        guard !initialWindowHandled else { return false }
        initialWindowHandled = true
        return launchedAtLogin
    }

    /// The main window is open → show the Dock icon and bring the app forward.
    func windowDidOpen() {
        setDockIconVisible(true)
        NSApp.activate()
    }

    /// The main window closed → hide the Dock icon; the app stays in the menu bar.
    func windowDidClose() {
        setDockIconVisible(false)
    }

    private func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

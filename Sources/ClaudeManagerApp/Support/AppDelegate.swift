import AppKit

/// AppKit delegate wired in via `NSApplicationDelegateAdaptor`. It owns the app lifecycle
/// and Dock-icon (activation-policy) behavior that SwiftUI's `Window` scene doesn't expose
/// declaratively:
///
/// - **Stay resident in the menu bar** after the last window closes, instead of quitting
///   (`applicationShouldTerminateAfterLastWindowClosed` → false). The reliable quit is
///   "Quit Claude Manager" in the menu bar (⌘Q also works while a window — and thus the
///   app menu bar — is present); both call `NSApp.terminate`.
/// - **Reopen the main window** on a Dock-icon click while no window is visible, via the
///   injected `reopenMainWindow` (AppKit can't invoke SwiftUI's window actions directly).
/// - **The Dock icon follows the window.** The app is `.regular` (Dock icon) while a
///   standard window is open and `.accessory` (menu-bar-only) when none is — driven by the
///   main window's appear/disappear (`MainWindowLaunchBinder` → `windowDidOpen` /
///   `windowDidClose`). A launch triggered at login starts menu-bar-only and dismisses its
///   auto-opened window; a manual launch keeps the window (see `applicationDidFinishLaunching`
///   and `shouldDismissInitialWindow`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reopens the main window. Set by the `Window` scene once its content appears and
    /// stays valid for the life of the process (the scene lives in `body` even while its
    /// window is closed). `nil` only before that first appearance, a harmless no-op.
    var reopenMainWindow: (() -> Void)?

    /// Whether this process's launch was *not* a plain user launch. macOS exposes no
    /// documented SMAppService signal for "launched at login", so we start from the legacy
    /// `NSApplication.launchIsDefaultUserInfoKey` (`false` ⇒ not a default user launch).
    /// This also covers open/print/Services and **saved-state restoration**, so it is not
    /// login on its own — the dismiss decision additionally requires the app to be
    /// inactive (`shouldDismissInitialWindow`), which a login/background launch is and a
    /// manual (even state-restoring) launch is not.
    private var launchWasNonDefault = false
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
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        launchWasNonDefault = isDefaultLaunch == false
        // Tentative: a non-default launch starts menu-bar-only. The window lifecycle
        // (windowDidOpen/Close) reconciles this once the window appears — a restoring
        // manual relaunch is non-default too, but keeps its window and flips back to
        // `.regular`.
        setDockIconVisible(!launchWasNonDefault)
    }

    /// Whether the initial (auto-opened) launch window should be dismissed to keep a login
    /// launch quiet. One-shot, and only when the launch was non-default **and** the app is
    /// inactive — i.e. a background login/auto start, not a foreground manual launch (which
    /// is active even when macOS restores its saved window). Every later window returns
    /// `false`.
    func shouldDismissInitialWindow() -> Bool {
        guard !initialWindowHandled else { return false }
        initialWindowHandled = true
        return launchWasNonDefault && !NSApp.isActive
    }

    /// The main window is open → show the Dock icon and bring the app forward.
    func windowDidOpen() {
        setDockIconVisible(true)
        NSApp.activate()
    }

    /// The main window closed → hide the Dock icon and stay in the menu bar, but only if no
    /// other standard window (Settings, a Sparkle dialog) is still on screen — otherwise
    /// `.accessory` would strip the Dock icon and app menu bar from a visible window.
    /// Deferred a tick so the just-closed window has already left `NSApp.windows`.
    func windowDidClose() {
        Task { @MainActor in
            if !self.hasVisibleStandardWindow() { self.setDockIconVisible(false) }
        }
    }

    /// Whether any standard, on-screen window remains (excludes panels and the menu-bar
    /// status item, which can't become main).
    private func hasVisibleStandardWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

import AppKit

/// AppKit delegate wired in via `NSApplicationDelegateAdaptor`. Its only job is the app
/// lifecycle that SwiftUI's `Window` scene doesn't expose declaratively:
///
/// - **Stay resident in the menu bar** after the last window closes, instead of quitting.
///   A SwiftUI app with a `Window` scene defaults
///   `applicationShouldTerminateAfterLastWindowClosed` to `true`, and the `MenuBarExtra`
///   status item doesn't count as a window — so closing the window would take the tray
///   presence down with it. Explicit quit (⌘Q, or "Quit Claude Manager") still
///   terminates: both call `NSApp.terminate`, which bypasses this delegate hook.
/// - **Reopen the main window** on a Dock-icon click while no window is visible. The
///   actual reopen is a SwiftUI `openWindow`, injected from the scene into
///   `reopenMainWindow`, because AppKit can't invoke SwiftUI's window actions directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reopens the main window. Set by the `Window` scene once its content appears and
    /// stays valid for the life of the process (the scene lives in `body` even while its
    /// window is closed). `nil` only before that first appearance, where a reopen is a
    /// harmless no-op.
    var reopenMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenMainWindow?() }
        return true
    }
}

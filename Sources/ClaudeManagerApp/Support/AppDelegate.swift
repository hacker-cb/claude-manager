import AppKit
import UserNotifications

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
/// - **The Dock icon follows the windows.** The app is `.regular` (Dock icon) while any
///   standard window is on screen and `.accessory` (menu-bar-only) when none is. Opening a
///   tracked scene (`windowDidAppear`) shows it immediately; closing one (`windowDidDisappear`)
///   re-checks `NSApp.windows` and hides it only when nothing standard remains — so a still-open
///   Settings window or Sparkle dialog keeps the Dock icon. A launch triggered at login starts
///   menu-bar-only and dismisses its auto-opened window; a manual launch keeps the window
///   (see `applicationDidFinishLaunching` / `shouldDismissInitialWindow`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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

    /// Sink for inbound `claude://` deep links, wired by `AppModel` once it exists.
    /// Setting it drains any URLs that arrived before wiring (a link can launch the app
    /// menu-bar-only, before the model registers).
    var deepLinkHandler: (([URL]) -> Void)? {
        didSet { drainPendingDeepLinks() }
    }

    private var pendingDeepLinks: [URL] = []

    /// The live delegate instance. SwiftUI's `@NSApplicationDelegateAdaptor` keeps its own
    /// internal object as `NSApp.delegate` and only *forwards* delegate callbacks to this
    /// one, so `NSApp.delegate as? AppDelegate` is always nil — code that needs the real
    /// delegate (to wire the deep-link sink from `AppModel`) reaches it through here instead.
    /// Weak: SwiftUI owns the lifetime; there is exactly one for the life of the process.
    private(set) weak static var shared: AppDelegate?

    /// How long the pointer must rest before a tooltip appears, in **milliseconds**.
    ///
    /// AppKit's own default is 1500 ms, which is a long time to hold still over a sidebar row
    /// whose reset countdown and freshness live only in the tooltip — the compact surfaces here
    /// deliberately print a figure and put the qualifiers behind hover, so hover has to be cheap.
    private static let toolTipDelayMilliseconds = 400

    override init() {
        super.init()
        Self.shared = self
        // `NSToolTipManager` reads this undocumented default once, when it is first created, and
        // exposes no public API for the delay — so it has to be in place before the first tooltip,
        // which `init()` (the delegate is built during SwiftUI's app setup) guarantees.
        //
        // The *registration* domain on purpose: it is the lowest-priority domain, so anyone who
        // has set `NSInitialToolTipDelay` globally keeps their own value, and nothing is written
        // to the app's preferences. If a future macOS stops reading the key we silently fall back
        // to AppKit's 1500 ms — a slower tooltip, never a broken one.
        UserDefaults.standard.register(
            defaults: ["NSInitialToolTipDelay": Self.toolTipDelayMilliseconds]
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// macOS delivers `claude://` opens here (reliable for a menu-bar app, unlike a
    /// scene `.onOpenURL` that needs a live window). Buffer until the model is wired.
    func application(_: NSApplication, open urls: [URL]) {
        let rendered = urls.map(\.logDescription).joined(separator: ", ")
        guard let deepLinkHandler else {
            Log.deepLink
                .info(
                    "open(urls:) received \(urls.count, privacy: .public) URL(s), handler not wired yet — buffering: [\(rendered, privacy: .public)]"
                )
            pendingDeepLinks.append(contentsOf: urls)
            return
        }
        Log.deepLink
            .info(
                "open(urls:) received \(urls.count, privacy: .public) URL(s), handler wired — dispatching: [\(rendered, privacy: .public)]"
            )
        deepLinkHandler(urls)
    }

    private func drainPendingDeepLinks() {
        guard let deepLinkHandler, !pendingDeepLinks.isEmpty else { return }
        let urls = pendingDeepLinks
        pendingDeepLinks = []
        Log.deepLink.info("draining \(urls.count, privacy: .public) buffered URL(s) to the now-wired handler")
        deepLinkHandler(urls)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenMainWindow?() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        launchWasNonDefault = isDefaultLaunch == false
        // Tentative: a non-default launch starts menu-bar-only. The window lifecycle
        // (windowDidAppear/Disappear) reconciles this once the window appears — a restoring
        // manual relaunch is non-default too, but keeps its window and flips back to
        // `.regular`.
        setDockIconVisible(!launchWasNonDefault)
        // Without this, every notification the app posts is **silently dropped while the app
        // is frontmost** — UserNotifications only presents to an active app if a delegate
        // says so. That hit exactly the cases the notifications exist for: the staged-update
        // nag, the forced-restart warning, the "your profiles were left closed" notice, and
        // the usage-limit warnings — all posted from a refresh the user may well have
        // triggered themselves, with the app in front.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Present notifications even while the app is active — see the delegate assignment
    /// above.
    ///
    /// `.sound` is included deliberately: `AppModel+UsageNotifications` sets
    /// `content.sound = .default` only for a *critical* limit warning, and omitting the
    /// option here would mute exactly that escalation in its most likely moment — the user
    /// looking at the app when the limit fills. A notification with no sound configured stays
    /// silent either way.
    ///
    /// `nonisolated` because the protocol hands over non-`Sendable` arguments, and this
    /// implementation reads none of them — nor any actor state. It answers a constant.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
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

    /// A tracked window (main or Settings) appeared → show the Dock icon and bring the app
    /// forward. A window being on screen is enough to warrant `.regular`.
    func windowDidAppear() {
        setDockIconVisible(true)
        NSApp.activate()
    }

    /// A tracked window disappeared → re-sync the Dock icon with what's actually on screen:
    /// stay `.regular` while any standard window remains (another tracked scene, or an
    /// untracked AppKit window like a Sparkle update dialog), else drop to `.accessory` and
    /// stay in the menu bar.
    ///
    /// Deferred with `DispatchQueue.main.async` so the scan runs on the **next** runloop
    /// cycle — after AppKit has finished closing the window and dropped it from
    /// `NSApp.windows` — rather than as an eager task continuation that could still see the
    /// closing window. We're on the main thread there, so `assumeIsolated` reaches the
    /// main-actor state safely.
    func windowDidDisappear() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.setDockIconVisible(self.hasVisibleStandardWindow())
            }
        }
    }

    /// Whether any standard, on-screen window remains (excludes panels — e.g. Sparkle's
    /// "you're up to date" alert — and the menu-bar status item, which can't become main).
    private func hasVisibleStandardWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

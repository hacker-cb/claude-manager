import AppKit
import SwiftUI

/// "Menu bar only" — runs the app as an `.accessory` (menu-bar-resident) app with **no
/// Dock icon**, instead of the default `.regular`. The window stays reachable from the
/// menu bar ("Open Claude Manager"). Off by default: the app ships with a Dock icon and
/// a full window UI (list / detail / editor / Doctor).
///
/// The preference is persisted; the live activation policy is reconciled with it on
/// toggle (`didSet`) and at launch (`AppDelegate.applicationDidFinishLaunching`). macOS
/// 14 has no declarative way to keep the `Window` scene from opening at launch
/// (`.defaultLaunchBehavior(.suppressed)` is macOS 15+), so the scene closes its own
/// initial window in `onAppear` when menu-bar-only — see `shouldDismissLaunchWindow`.
@MainActor
final class MenuBarChrome: ObservableObject {
    /// When `true`, no Dock icon; the app lives only in the menu bar.
    @Published var menuBarOnly: Bool {
        didSet {
            defaults.set(menuBarOnly, forKey: PreferenceKeys.menuBarOnly)
            Self.apply(menuBarOnly: menuBarOnly)
        }
    }

    /// Whether the app's *initial* (launch-opened) window has yet to be handled. Consumed
    /// once, on that window's first appearance, so a menu-bar-only launch closes it — and
    /// a window the user deliberately opens **later** is never auto-closed. Process-scoped
    /// (not persisted): each launch re-arms it.
    private var launchWindowPending = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load the stored preference only — the launch-time policy is applied by
        // `AppDelegate.applicationDidFinishLaunching`, the sanctioned point to set the
        // activation policy (setting it this early can be overridden as SwiftUI starts).
        menuBarOnly = defaults.bool(forKey: PreferenceKeys.menuBarOnly)
    }

    /// Match the Dock-icon visibility (activation policy) to `menuBarOnly`. Idempotent;
    /// called from the toggle and at launch.
    static func apply(menuBarOnly: Bool) {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }

    /// Call on the main window's first appearance. Returns `true` exactly once, and only
    /// for a menu-bar-only launch, meaning the caller should dismiss the just-opened
    /// window to keep the launch quiet. Every later call returns `false`, so a
    /// user-opened window is left alone.
    func shouldDismissLaunchWindow() -> Bool {
        guard launchWindowPending else { return false }
        launchWindowPending = false
        return menuBarOnly
    }
}

import AppKit
import SwiftUI

/// Presents the deep-link account picker in a small floating window. A menu-bar app may
/// have no window open when a link arrives, so the picker brings its own (rather than a
/// sheet that would need a host).
///
/// It is the window's delegate so **every** close path — Pick, Cancel, or the native
/// close button — funnels through `windowWillClose`, which clears state and invokes
/// `onDismiss` exactly once. Without that, closing via the traffic-light button would
/// leave `isPresenting` stuck true and the queued links would never advance.
@MainActor
final class DeepLinkPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onDismiss: (() -> Void)?

    /// Whether a picker is currently on screen — the model shows queued links one at a
    /// time, presenting the next only once this returns `false`.
    var isPresenting: Bool {
        window != nil
    }

    /// Present the picker. `onDismiss` fires once after the window closes for *any* reason
    /// (pick, cancel, or the close button), so the caller can advance its queue. The model
    /// only calls this while idle (`!isPresenting`), so there is never a prior window.
    func present(
        url: URL,
        targets: [DeepLinkTarget],
        onPick: @escaping (DeepLinkTarget) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        let view = DeepLinkPickerView(
            url: url,
            targets: targets,
            // Pick/Cancel just request a close; windowWillClose runs onDismiss once.
            onPick: { [weak self] target in onPick(target); self?.window?.close() },
            onCancel: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Open in Claude account"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The single cleanup path for every close route. `windowWillClose` fires once per
    /// close, so no extra idempotency guard is needed; nil the window first so the
    /// `onDismiss` → present-next hop sees `isPresenting == false`.
    func windowWillClose(_: Notification) {
        window = nil
        let onDismiss = onDismiss
        self.onDismiss = nil
        onDismiss?()
    }
}

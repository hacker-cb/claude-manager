import AppKit
import SwiftUI

/// Presents the deep-link profile picker in a small floating window. A menu-bar app may
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
    /// Set the instant a present is scheduled — before the window exists. The model
    /// presents from an async context that first `await`s a refresh, and `window` (the
    /// other truth) isn't set until `present`. Reserving synchronously closes that gap so
    /// a second link arriving mid-`await` can't pass the idle check and double-present.
    private var reserved = false

    /// Whether a picker is on screen *or* reserved for one — the model shows queued links
    /// one at a time, presenting the next only once this returns `false`.
    var isPresenting: Bool {
        window != nil || reserved
    }

    /// Reserve the presenter synchronously, so the model's idle check is race-free across
    /// the pre-`present` `await`. `present` clears it once `window` becomes the truth.
    func reserve() {
        reserved = true
    }

    /// Release a reservation made by `reserve()` *without* presenting — for when the caller
    /// decides not to show a picker after all (e.g. Claude went missing). Leaves `isPresenting`
    /// false so the queue can advance instead of stalling on a reservation that never opened.
    func cancelReservation() {
        reserved = false
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
        window.title = "Open in Claude profile"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        self.window = window
        reserved = false // the window is now the source of truth
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

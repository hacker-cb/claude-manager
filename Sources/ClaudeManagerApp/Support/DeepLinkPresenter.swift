import AppKit
import SwiftUI

/// Presents the deep-link account picker in a small floating window. A menu-bar app may
/// have no window open when a link arrives, so the picker brings its own (rather than a
/// sheet that would need a host). Replaces any picker already on screen.
@MainActor
final class DeepLinkPresenter {
    private var window: NSWindow?

    /// Whether a picker is currently on screen — the model shows queued links one at a
    /// time, presenting the next only once this returns `false`.
    var isPresenting: Bool {
        window != nil
    }

    /// Present the picker. `onDismiss` fires after the window closes for *either* outcome
    /// (pick or cancel), so the caller can advance its queue. Any picker already on screen
    /// is closed first (its `onDismiss` will advance the queue).
    func present(
        url: URL,
        targets: [DeepLinkTarget],
        onPick: @escaping (DeepLinkTarget) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        close()
        let view = DeepLinkPickerView(
            url: url,
            targets: targets,
            onPick: { [weak self] target in self?.close(); onPick(target); onDismiss() },
            onCancel: { [weak self] in self?.close(); onDismiss() }
        )
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Open in Claude account"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

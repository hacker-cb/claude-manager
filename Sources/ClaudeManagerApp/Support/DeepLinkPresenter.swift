import AppKit
import SwiftUI

/// Presents the deep-link account picker in a small floating window. A menu-bar app may
/// have no window open when a link arrives, so the picker brings its own (rather than a
/// sheet that would need a host). Replaces any picker already on screen.
@MainActor
final class DeepLinkPresenter {
    private var window: NSWindow?

    func present(url: URL, targets: [DeepLinkTarget], onPick: @escaping (DeepLinkTarget) -> Void) {
        let view = DeepLinkPickerView(
            url: url,
            targets: targets,
            onPick: { [weak self] target in self?.close(); onPick(target) },
            onCancel: { [weak self] in self?.close() }
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

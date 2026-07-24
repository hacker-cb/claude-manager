import AppKit
import ClaudeManagerCore
import SwiftUI
import UserNotifications

/// Watching the real Claude.app update out from under running instances. Split from `AppModel`
/// so the model file stays within its length budget; the state it drives (`monitorTask`,
/// `activationObserver`) lives there because stored properties can't move to an extension.
extension AppModel {
    // MARK: - Claude update monitoring

    /// Start watching for the real Claude.app updating out from under running
    /// instances: refresh when the user returns to the manager, and poll (while the app
    /// is frontmost) so a background update surfaces even with the window open.
    /// Idempotent — safe to call from `.task` on every appearance.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A cheap guaranteed re-check on top of the Darwin observer: if Claude
                // grabbed the handler while we were away, take it back.
                self.deepLinkService.reassertIfNeeded()
                // Skip the rescan while a staged-update apply is in flight (same reason as
                // the poll loop: avoid a relaunch during ShipIt's swap window).
                guard !self.isApplyingStagedUpdate else { return }
                await self.reconcile()
            }
        }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                // Poll only while frontmost — a backgrounded menu-bar app catches up
                // via didBecomeActive instead of spawning `ps` every minute forever.
                // @MainActor so NSApp.isActive is read on the main thread. Skip while a
                // staged-update apply is in flight: re-probing is fine, but a relaunch it
                // could trigger during the swap window would trip ShipIt's Gate 2.
                if NSApp.isActive, !isApplyingStagedUpdate { await reconcile() }
            }
        }
    }

    /// Cancel the poll and drop the activation observer. The root model normally lives
    /// for the process, but explicit teardown keeps `startMonitoring` restartable.
    ///
    /// Usage polling is deliberately **not** torn down here: it has its own lifecycle (the master
    /// switch via `applyUsageTrackingChange`, the interval/adaptive didSets, and `performLaunchTasks`),
    /// and `startMonitoring` doesn't start it — tying only the stop to this pair would strand the
    /// poll after a monitor restart. Turn usage polling off through the master switch instead.
    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Re-read the on-disk Claude version and rescan running state, so a version skew
    /// (its badge, banner, and notification) appears without a manual refresh. The
    /// locate runs off the main actor (LaunchServices + plist reads block); a missing
    /// Claude is left to the persistent banner rather than re-raising the alert.
    func reconcile() async {
        await locateOffMain()
        guard realClaude != nil else { return }
        await refresh()
    }
}

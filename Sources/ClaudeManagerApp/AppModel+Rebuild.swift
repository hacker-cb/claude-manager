import ClaudeManagerCore
import Foundation

/// Regenerating launchers from the current wrapper format — one, or all of them — and
/// reporting what a batch could not finish. Split out of `AppModel` to keep that file within
/// its length budget.
@MainActor
extension AppModel {
    /// Rebuild one launcher from the current wrapper format (script + Info.plist + icon).
    /// Used both to clear a stale launcher and to force a fresh regenerate.
    func rebuild(_ profile: Profile) async {
        // Refresh even when the rebuild failed — `perform` returning nil means it threw, and
        // the usual reason is a launcher that is no longer where we think it is. Returning
        // early would leave that dead row in the sidebar, offering actions against a bundle
        // that is gone, until the next monitor tick.
        let result = await perform { store in try store.rebuild(profile) }
        if result?.iconChanged == true { setDockRefreshPending(true) }
        noteLiveRewrites(result?.liveRewrite.map { [$0] } ?? [])
        await refresh()
    }

    /// Rebuild every launcher. Per-launcher failures are collected by the core (the batch
    /// never aborts); surface them as a non-fatal notice via the same channel `stop` uses for
    /// its running warning.
    func rebuildAll() async {
        guard let result = await perform({ store in try store.rebuildAll() }) else { return }
        if result.dockRefreshPending { setDockRefreshPending(true) }
        noteLiveRewrites(result.liveRewrites)
        if let notice = rebuildAllNotice(for: result) {
            currentError = AppError(title: "Some launchers weren't rebuilt", message: notice)
        }
        await refresh()
    }

    /// A non-fatal summary when a batch rebuild didn't touch every launcher, or `nil` when
    /// all were rebuilt cleanly. Running launchers are no longer a category here: they are
    /// rebuilt like any other, and each carries its own "Restart to apply" nudge rather than
    /// a batch-wide warning nobody could act on from this alert.
    private func rebuildAllNotice(for result: RebuildAllResult) -> String? {
        var parts: [String] = []
        if !result.failed.isEmpty {
            let c = result.failed.count
            let names = result.failed.map(\.profile.displayName).joined(separator: ", ")
            parts.append("Failed to rebuild \(c) launcher\(c == 1 ? "" : "s"): \(names).")
            // Carry the reason through, not just the names: a signing failure leaves the
            // launcher unable to start, and without this the user has nothing to act on.
            // Distinct reasons only — a shared cause (the usual case) prints once.
            let reasons = Set(result.failed.map(\.reason)).sorted()
            parts.append(reasons.joined(separator: " "))
        }
        guard !parts.isEmpty else { return nil }
        let n = result.rebuilt.count
        return "Rebuilt \(n) launcher\(n == 1 ? "" : "s"). " + parts.joined(separator: " ")
    }
}

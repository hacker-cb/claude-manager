import AppKit
import ClaudeManagerCore

/// Reveal-in-Finder helpers — a profile's data dir and launcher, and the default profile's
/// real Claude.app. Split from `AppModel` to keep the core file within its length budget.
extension AppModel {
    func revealProfileData(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileURL])
    }

    func revealLauncher(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.appURL])
    }

    /// Reveal the real Claude.app (the default profile's bundle) in Finder. No-op if it
    /// isn't located — the missing-Claude banner covers that case.
    func revealRealClaude() {
        guard let real = realClaude else { return }
        NSWorkspace.shared.activateFileViewerSelecting([real.appURL])
    }
}

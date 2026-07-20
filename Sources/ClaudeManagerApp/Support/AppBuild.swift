import ClaudeManagerCore
import Foundation

/// Facts about the running bundle that gate the two behaviours which reach *outside* the
/// app into macOS-wide state: the Login Items database and the `claude://` default
/// handler. One home for both, so the app can't answer "am I the shipped build?"
/// differently in two places.
///
/// Both answers are read off the bundle rather than a compile-time flag, and they are
/// deliberately *different* questions — see each property.
enum AppBuild {
    /// Whether this is a released build (CI injected a tag version) rather than any local
    /// one — including a locally archived Release, which is still unsigned and unnotarized.
    ///
    /// Gates the things that need a real Developer ID identity to work at all: Sparkle's
    /// updater (a dev build reads every published release as newer than its `0.0.0`
    /// placeholder) and the login item (macOS only honours `SMAppService` registration for
    /// a signed + notarized app — see docs/RELEASING.md § Launch at login).
    static var isDistribution: Bool {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? CoreConstants.devMarketingVersion
        return CoreConstants.isDistributionBuild(marketingVersion: marketingVersion)
    }

    /// Whether this bundle may act as the system `claude://` handler — true only when it
    /// declares the scheme, which the Release identity does and the Debug (dev) one
    /// deliberately does not (project.yml `settings.configs`).
    ///
    /// Keyed on the declaration and not on ``isDistribution`` on purpose: `make run
    /// CONFIG=Release` builds the shipping identity locally *in order to* exercise the
    /// broker, and that build should broker. The bundle's own plist is the honest answer —
    /// a bundle that doesn't declare the scheme cannot be its handler regardless.
    static var canBrokerDeepLinks: Bool {
        BundleIdentity.declaresURLScheme(CoreConstants.claudeURLScheme, in: Bundle.main.infoDictionary)
    }
}

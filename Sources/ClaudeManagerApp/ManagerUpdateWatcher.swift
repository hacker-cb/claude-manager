import ClaudeManagerCore
import Foundation
import Sparkle

/// Keeps the one fact Sparkle does not otherwise leave anywhere the window can read: that a
/// newer Claude Manager exists.
///
/// Sparkle owns its own update entirely — the appcast, the download, the signature check, the
/// relaunch — and says so through a modal window that opens, is dismissed, and takes the news
/// with it. Between those windows nothing in the app knows a release is out, so a version
/// published on Tuesday reaches a user who never opens the menu on Friday, if at all. This
/// watcher is the standing answer: Sparkle's own probe, whose results feed the window's update
/// control beside Claude's.
///
/// **It never installs anything.** The probe (`checkForUpdateInformation`) shows no UI and
/// offers nothing; pressing the control hands over to `updater.checkForUpdates()`, which is
/// the same modal flow the menu bar has always opened. What this adds is that the offer is
/// *visible* without being asked for.
final class ManagerUpdateWatcher: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the toolbar reads. Written only from Sparkle's delegate callbacks, which arrive on
    /// the main thread (its documented contract), so the publish is on the main thread too.
    @Published private(set) var state: ManagerUpdateState = .idle

    /// The updater this watches, wired after `SPUStandardUpdaterController` exists — it takes
    /// its delegate at construction, so the watcher is built first and learns its updater
    /// second. Unowned-by-design: the controller lives for the process.
    private weak var updater: SPUUpdater?

    /// When the probe last ran, so an app activated ten times an hour asks once.
    private var lastProbe: Date?

    /// How long a probe's answer stands before another is worth making. Sparkle's own schedule
    /// is a day by default; this is the *display* refresh, and four hours is the same cadence
    /// the Claude updater's check uses.
    private static let probeInterval: TimeInterval = 4 * 60 * 60

    // MARK: - Wiring

    @MainActor
    func attach(to updater: SPUUpdater) {
        self.updater = updater
    }

    /// Ask Sparkle whether a release exists, at most once per ``probeInterval``.
    ///
    /// Three gates, and each is a state where probing would be wrong rather than merely
    /// wasteful:
    ///
    /// - **Automatic checks off.** The setting is the user saying not to reach the network for
    ///   this; a "silent" check is exactly the thing they switched off.
    /// - **A session in progress.** `checkForUpdateInformation` does nothing during one, and
    ///   the session — a visible update window — is already telling them more than this could.
    /// - **A dev build.** The updater is dormant (`startingUpdater: AppBuild.isDistribution`),
    ///   and this build's `0.0.0` placeholder reads as older than every published release, so
    ///   a probe here would report an update to overwrite the developer's own working build.
    @MainActor
    func probeIfDue(now: Date = Date()) {
        guard AppBuild.isDistribution, let updater else { return }
        guard updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
        if let lastProbe, now.timeIntervalSince(lastProbe) < Self.probeInterval { return }
        lastProbe = now
        updater.checkForUpdateInformation()
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle calls these on the main thread; `assumeIsolated` states that rather than
    /// hopping, so the toolbar changes in the same turn the answer arrives.
    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            // `displayVersionString` is what the appcast means for humans (`0.16.0`);
            // `versionString` is the build number, which is what the feed sorts on and not
            // what any other surface in this app prints.
            state = .available(version: item.displayVersionString)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        // Also the path a user's "Skip this version" takes: a skipped release stops being
        // found, so the control stops offering it — which is the whole of what skipping means.
        MainActor.assumeIsolated { state = .idle }
    }
}

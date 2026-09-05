import ClaudeManagerCore
import Foundation
import Sparkle

/// Keeps the one fact Sparkle does not otherwise leave anywhere the window can read: that a
/// newer Claude Manager exists.
///
/// Sparkle owns its own update entirely — the appcast, the download, the signature check, the
/// relaunch — and says so through a modal window that opens, is dismissed, and takes the news
/// with it. Between those windows nothing in the app knows a release is out, so the offer is
/// only ever as visible as the moment it appeared in. This watcher is the standing answer: it
/// listens to the checks Sparkle already makes and publishes a `ManagerUpdateState` the
/// window's toolbar reads beside Claude's own.
///
/// **It never asks Sparkle to check, and it never installs anything.** Not asking is a
/// decision rather than an omission: every check — the probing `checkForUpdateInformation`
/// included — invalidates Sparkle's scheduled timer and re-stamps `SULastCheckTime`, so a
/// refresh made here more often than Sparkle's own interval (a day, by default) postpones the
/// scheduled cycle indefinitely. That cycle is the one that downloads in the background and
/// puts up the reminder, so a "keep the toolbar fresh" probe every few hours is also a switch
/// that quietly turns *Automatically download updates* into a setting that never downloads
/// anything. What this class does instead is remember: the delegate callbacks fire for
/// Sparkle's own scheduled and user-initiated checks, and the answer is persisted so it
/// survives a relaunch.
///
/// Pressing the control hands over to `updater.checkForUpdates()`, the same modal flow the
/// menu bar has always opened.
final class ManagerUpdateWatcher: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the toolbar reads. Written only from Sparkle's delegate callbacks, which arrive on
    /// the main thread (its `NS_SWIFT_UI_ACTOR` contract), so the publish is on it too.
    @Published private(set) var state: ManagerUpdateState

    private let defaults: UserDefaults
    /// This build's `CFBundleVersion` — the baseline a remembered release is measured against.
    private let installedBuild: String?

    init(
        defaults: UserDefaults = .standard,
        installedBuild: String? = AppBuild.buildVersion,
        isDistribution: Bool = AppBuild.isDistribution
    ) {
        self.defaults = defaults
        self.installedBuild = installedBuild
        // A local build shares the released app's defaults domain when it carries the shipping
        // identity (`make run CONFIG=Release`), and its `0.0.0` / `1` placeholders read as
        // older than everything — so it would restore the release's record and show an offer
        // its own dormant updater (`startingUpdater: AppBuild.isDistribution`) can do nothing
        // about, with no callback able to clear it. The record itself is left alone: it is the
        // released app's, and this build has no business deleting it.
        state = isDistribution
            ? .restored(
                version: defaults.string(forKey: PreferenceKeys.managerUpdateVersion),
                build: defaults.string(forKey: PreferenceKeys.managerUpdateBuild),
                installedBuild: installedBuild
            )
            : .idle
        super.init()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            // Both, because they answer different questions: `displayVersionString` is what
            // the appcast means for humans (`0.16.0`) and the only one worth printing, while
            // `versionString` is `CFBundleVersion` — what Sparkle itself compares, and the
            // only one that is monotonic across a re-dispatched tag.
            remember(version: item.displayVersionString, build: item.versionString)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        // Only a genuine "nothing newer" reaches this — a feed that could not be loaded aborts
        // elsewhere — so a network outage does not wipe a release found yesterday.
        MainActor.assumeIsolated { forget() }
    }

    /// Sparkle's own window is where a release is accepted or refused, and those answers have
    /// to reach this control too.
    ///
    /// **Skip is not "no update".** `updaterDidNotFindUpdate` is not called for it — the update
    /// *was* found in that session — and a skipped release is filtered out only on the *next*
    /// check, a day away. Without this the toolbar would go on advertising a version the user
    /// has just declined, and pressing it would find that version again, since an explicit
    /// check ignores skips.
    nonisolated func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            switch choice {
            case .skip:
                forget()
            case .install, .dismiss:
                // Neither is a refusal, so the record stands. Install least of all: Sparkle
                // reports this choice from the *found-update alert*, and a download cancelled
                // or failed afterwards aborts without another choice callback — clearing here
                // would leave the toolbar silent about a release nothing has declined, until a
                // scheduled check a day away, or never with automatic checks switched off.
                // A successful install relaunches into a build whose own `CFBundleVersion` is
                // the newer one, and `restored` drops the record there.
                remember(version: updateItem.displayVersionString, build: updateItem.versionString)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Remembering

    /// Publish and persist a release, through `restored` rather than by assignment so the one
    /// guard that matters — never offer a build this app has already caught up with — has a
    /// single home.
    @MainActor
    private func remember(version: String, build: String) {
        let news = ManagerUpdateState.restored(
            version: version, build: build, installedBuild: installedBuild
        )
        state = news
        guard news != .idle else { return forget() }
        defaults.set(version, forKey: PreferenceKeys.managerUpdateVersion)
        defaults.set(build, forKey: PreferenceKeys.managerUpdateBuild)
    }

    @MainActor
    private func forget() {
        state = .idle
        defaults.removeObject(forKey: PreferenceKeys.managerUpdateVersion)
        defaults.removeObject(forKey: PreferenceKeys.managerUpdateBuild)
    }
}

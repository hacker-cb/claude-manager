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
/// **It takes the install itself, though.** With background downloads on, Sparkle stages a
/// build and would then run its own reminder schedule — the modal that interrupts whatever is
/// on screen to ask. `willInstallUpdateOnQuit:` returns `true` instead, which stalls that
/// schedule and hands over the handler that installs immediately, so the offer waits in the
/// toolbar until it is pressed. Nothing is lost by waiting: Sparkle installs a staged build
/// when the app quits either way.
///
/// Where nothing is staged, pressing the control hands over to `updater.checkForUpdates()` —
/// the same modal flow the menu bar has always opened.
@MainActor
final class ManagerUpdateWatcher: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the toolbar reads. Written only from Sparkle's delegate callbacks, which the
    /// protocol declares `NS_SWIFT_UI_ACTOR` — main-actor in Swift, which is why this class is
    /// too and none of it hops.
    @Published private(set) var state: ManagerUpdateState

    /// Sparkle's own handler for "install the staged build now and relaunch", kept from
    /// `willInstallUpdateOnQuit:`. Nil unless a build is staged in *this* session — the
    /// handler cannot outlive it, which is why `.downloaded` is never restored from disk.
    private var installStagedBuild: (() -> Void)?

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

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        // Both, because they answer different questions: `displayVersionString` is what
        // the appcast means for humans (`0.16.0`) and the only one worth printing, while
        // `versionString` is `CFBundleVersion` — what Sparkle itself compares, and the
        // only one that is monotonic across a re-dispatched tag.
        remember(version: item.displayVersionString, build: item.versionString, staged: false)
    }

    func updaterDidNotFindUpdate(_: SPUUpdater) {
        // Only a genuine "nothing newer" reaches this — a feed that could not be loaded aborts
        // elsewhere — so a network outage does not wipe a release found yesterday.
        forget()
    }

    /// A build has been fetched and staged, and Sparkle is asking who presents it.
    ///
    /// **Returning `true` takes that over**, which is the whole point of this class: Sparkle's
    /// own answer is a modal reminder on its own schedule, and this app's model — the one it
    /// already applies to Claude — is that downloading happens unattended and installing waits
    /// for a press. The handler is kept for that press.
    ///
    /// It costs nothing in safety: Sparkle installs a staged build when the app quits whether
    /// or not this is answered, so the worst case for an offer nobody presses is that it lands
    /// at the next quit, which is what it would have done anyway.
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // A critical update is the one case Sparkle escalates by itself — it presents that one
        // immediately rather than waiting to be found — and taking it over would trade an
        // escalation for a control the user has to go looking for. Handed straight back.
        guard !item.isCriticalUpdate else { return false }
        installStagedBuild = immediateInstallHandler
        remember(version: item.displayVersionString, build: item.versionString, staged: true)
        return true
    }

    /// The update cycle gave up after the build was staged.
    ///
    /// The handler kept from `willInstallUpdateOnQuit:` holds its driver weakly, so once
    /// Sparkle releases that driver the press is a silent no-op — and a panel still saying
    /// "ready to install" over a dead button is worse than one admitting the release has to be
    /// fetched again. Falls back to `.available`, whose press opens Sparkle's window and starts
    /// the download over.
    func updater(_: SPUUpdater, didAbortWithError _: Error) {
        installStagedBuild = nil
        if case let .downloaded(version) = state { state = .available(version: version) }
    }

    /// Install the staged build now and relaunch. No-op with nothing staged — the control that
    /// calls this is only shown in `.downloaded`, which is exactly when the handler exists.
    func installStagedUpdate() {
        installStagedBuild?()
    }

    /// Sparkle's own window is where a release is accepted or refused, and those answers have
    /// to reach this control too.
    ///
    /// **Skip is not "no update".** `updaterDidNotFindUpdate` is not called for it — the update
    /// *was* found in that session — and a skipped release is filtered out only on the *next*
    /// check, a day away. Without this the toolbar would go on advertising a version the user
    /// has just declined, and pressing it would find that version again, since an explicit
    /// check ignores skips.
    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
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
            remember(
                version: updateItem.displayVersionString,
                build: updateItem.versionString,
                // This class's own `state`, not the `SPUUserUpdateState` above — that parameter
                // is `_`, and the distinction matters: what counts is whether a build is staged
                // *here*, with a live handler behind it. Sparkle's own `.downloaded` stage is
                // reached on paths that hand this class no handler at all, and a panel offering
                // an install it cannot perform is the one thing to avoid.
                staged: state.isWaitingForAPress
            )
        @unknown default:
            break
        }
    }

    // MARK: - Remembering

    /// Publish and persist what Sparkle has just said.
    ///
    /// **Sparkle's answer is taken as given here.** Its own comparator decided this build is
    /// newer, and second-guessing that with `AvailableUpdate.isUpgrade` buys nothing and can
    /// disagree — an unreadable `CFBundleVersion` makes *every* release compare as "not news",
    /// and a staged build that goes in at the next quit regardless would then have been
    /// installed with the user shown nothing at all. The version check belongs to `restored`,
    /// which reads a record off disk where the app may genuinely have moved on since.
    private func remember(version: String, build: String, staged: Bool) {
        state = staged ? .downloaded(version: version) : .available(version: version)
        defaults.set(version, forKey: PreferenceKeys.managerUpdateVersion)
        defaults.set(build, forKey: PreferenceKeys.managerUpdateBuild)
    }

    private func forget() {
        state = .idle
        installStagedBuild = nil
        defaults.removeObject(forKey: PreferenceKeys.managerUpdateVersion)
        defaults.removeObject(forKey: PreferenceKeys.managerUpdateBuild)
    }
}

import Foundation

/// Whether a newer **Claude Manager** exists, as Sparkle last answered.
///
/// Deliberately thinner than ``ClaudeUpdateState``, and for a reason worth stating: this app
/// does not fetch, verify or install its own updates — Sparkle does all of it, including the
/// download, the signature check and the relaunch. What is left for this type to carry is what
/// Sparkle keeps to itself between its own dialogs: that a release is out there, and whether
/// it is already on disk waiting for a press.
///
/// There is still no `.downloading` and no `.failed`. A transfer in flight is behind Sparkle's
/// own window and finishes on its own; a failure belongs to Sparkle's reporting, which this
/// app has no better words for.
public enum ManagerUpdateState: Equatable, Sendable {
    /// Nothing found, or nothing asked yet.
    case idle
    /// Sparkle found a release newer than this build, and has not fetched it (yet).
    case available(version: String)
    /// Fetched, verified by Sparkle, and staged to install. Installing it is one press —
    /// and, press or not, it goes in when the app next quits.
    case downloaded(version: String)

    /// The release this state is about, when it is about one.
    public var version: String? {
        switch self {
        case .idle: nil
        case let .available(version), let .downloaded(version): version
        }
    }

    /// Whether the release is on disk, waiting only for someone to say so — the state that
    /// stands indefinitely, and the one whose control does something rather than opening a
    /// window that asks again.
    public var isWaitingForAPress: Bool {
        if case .downloaded = self { return true }
        return false
    }

    /// One line for a tooltip or a heading. Empty for `.idle`, which has nothing to say —
    /// the control it feeds is not shown at all in that state.
    public var statusLine: String {
        switch self {
        case .idle: ""
        case let .available(version): "Claude Manager \(version) is available."
        case let .downloaded(version): "Claude Manager \(version) is ready to install."
        }
    }

    /// What a remembered release means on *this* run.
    ///
    /// The state is remembered across launches because nothing else would rebuild it: Sparkle
    /// asks its feed on a schedule of its own — a day, by default — and this app deliberately
    /// does not ask on its behalf (a check made here resets that schedule, which is how an
    /// "automatically download updates" that never downloads anything is built). So a release
    /// found on Monday would be forgotten by Tuesday's launch and not found again until
    /// Wednesday.
    ///
    /// The installed build is the guard: a remembered release this build has caught up with —
    /// updated by hand, or by Sparkle itself — is not news, and an offer to install what is
    /// already running is worse than no offer at all.
    ///
    /// **It never answers `.downloaded`, even for a build Sparkle has already staged.** That
    /// state carries a promise this side of a relaunch cannot keep: the handler that installs
    /// it lives in the session Sparkle handed it to, and nothing persisted can call it. So a
    /// remembered release comes back as `.available`, whose press opens Sparkle's window —
    /// which finds the staged build and offers it, at the cost of one extra click and no lies.
    ///
    /// **Two versions, and they answer different questions.** `version` is the marketing one
    /// (`0.16.0`), which is what a person reads; `build` is `CFBundleVersion` — the CI run
    /// number — which is what Sparkle itself compares and the only one that is monotonic. The
    /// difference is not academic here: a re-dispatched tag publishes the *same* marketing
    /// version at a higher build, which Sparkle offers and a marketing-version comparison would
    /// throw away. Unreadable either way answers `.idle`: `isUpgrade` is false for a baseline
    /// it cannot compare, which is the safe direction — an offer withheld, never one invented.
    public static func restored(
        version: String?,
        build: String?,
        installedBuild: String?
    ) -> ManagerUpdateState {
        guard let version, let build, AvailableUpdate.isUpgrade(build, over: installedBuild)
        else { return .idle }
        return .available(version: version)
    }
}

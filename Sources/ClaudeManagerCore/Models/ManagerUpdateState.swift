import Foundation

/// Whether a newer **Claude Manager** exists, as Sparkle last answered.
///
/// Deliberately thinner than ``ClaudeUpdateState``, and for a reason worth stating: this app
/// does not fetch, verify or install its own updates — Sparkle does all of it, including the
/// download, the signature check and the relaunch. What is left for this type to carry is the
/// one fact Sparkle keeps to itself between its own dialogs: that a release is out there.
///
/// So there is no `.downloading`, no `.ready` and no `.failed` here. A failure belongs to
/// Sparkle's own reporting, and a download that is in flight is behind its window.
public enum ManagerUpdateState: Equatable, Sendable {
    /// Nothing found, or nothing asked yet.
    case idle
    /// Sparkle's probe found a release newer than this build.
    case available(version: String)

    /// The release this state is about, when it is about one.
    public var version: String? {
        switch self {
        case .idle: nil
        case let .available(version): version
        }
    }

    /// One line for a tooltip or a heading. Empty for `.idle`, which has nothing to say —
    /// the control it feeds is not shown at all in that state.
    public var statusLine: String {
        switch self {
        case .idle: ""
        case let .available(version): "Claude Manager \(version) is available."
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

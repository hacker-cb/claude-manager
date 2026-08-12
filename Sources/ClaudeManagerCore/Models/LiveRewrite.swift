import Foundation

/// A launcher whose bundle was rewritten while its own instance was live.
///
/// The rewrite itself is safe, and that is the whole reason edits are no longer refused: a
/// launcher is a bash script that `exec`s the real Claude binary, so the running process is
/// **not** executing out of the bundle and holds nothing in it open — and
/// `LauncherBundle.build` assembles into a staging directory and swaps it in atomically. What
/// the live process does keep is the name and the Dock tile it launched with, and no rewrite
/// reaches those. So the user is told to restart *that instance* to see the change, instead
/// of being told to stop it before making one.
public struct LiveRewrite: Sendable, Equatable {
    /// The launcher as it stands *after* the write — so a rename carries the new bundle
    /// path, which is both the launcher's identity and what the next scan will report.
    public let profile: Profile
    /// The instance observed at the moment of the write. Carried, not just a flag, so the app
    /// can retire the nudge on the evidence that the restart happened — this pid gone or
    /// replaced — rather than on a guess.
    public let pid: Int32

    public init(profile: Profile, pid: Int32) {
        self.profile = profile
        self.pid = pid
    }
}

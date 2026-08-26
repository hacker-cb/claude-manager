import Foundation

/// What remains of Claude's own installer in this app: a way to ask whether it is running.
///
/// The machinery that *waited* on Squirrel — the staged-update probe, the two-gate apply, the
/// forced-restart deadline, the nightly window — is gone with the release that took updating
/// over. None of it was ever the point; all of it existed to survive an installer this app no
/// longer depends on.
///
/// Two things still ask. The installer refuses to swap the bundle while ShipIt might be
/// writing it, and the residue sweep refuses to delete a staged bundle out from under it.
/// Both matter because Squirrel is only *disabled*, not absent: a user can hand updating back
/// at any time, and an armed job can outlive the switch.
public extension ProfileStore {
    /// A probe for Claude's own installer, keyed to the real app's bundle id.
    func shipItProbe() -> ShipItProbe {
        ShipItProbe(
            bundleID: realClaude.bundleIdentifier(fileManager: fileManager)
                ?? CoreConstants.realClaudeBundleIDs[0],
            runner: runner
        )
    }
}

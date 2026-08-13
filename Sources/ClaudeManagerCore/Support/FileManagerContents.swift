import Foundation

public extension FileManager {
    /// A directory's visible entries, listed **by path** and rebuilt as URLs under the very
    /// `url` that was passed in.
    ///
    /// How this app enumerates a directory whenever the entries' **paths** matter — the
    /// launcher scan and Doctor's orphan sweep. (`directoryHasContents` and `hasTrashedTwin`
    /// ask only about names, and list by path themselves.) `contentsOfDirectory(at:)` is not
    /// used anywhere, because it loses a path's spelling twice over and both losses reach the
    /// user:
    ///
    /// - It **resolves symlinks** in the URLs it hands back, so scanning `/tmp/Apps` returns
    ///   `/private/tmp/Apps/…` — a spelling nothing else in the app derives, while `Profile.id`
    ///   *is* the launcher's path and a marker records whichever spelling its profile was
    ///   created with.
    /// - It **throws `ENOTDIR`** when the directory handed to it is itself a symlink (only the
    ///   final component is not followed), which a `try?` turns into "this directory is empty".
    ///
    /// Dot-names are always dropped — `.skipsHiddenFiles` did that for the URL overload, and it
    /// is what keeps `LauncherBundle.build`'s `.<name>.app.build-<uuid>` staging directories
    /// out of a scan.
    ///
    /// `skippingFlaggedHidden` covers the *other* half of `.skipsHiddenFiles`: the file
    /// system's own hidden flag, which `chflags hidden` sets without touching the name. It is
    /// off by default, and the two callers differ on purpose. A hidden **launcher** still runs
    /// and still claims its user-data directory, so `scan` must see it: dropped, it vanishes
    /// from the sidebar, from `rebuildAll`, and from the ownership checks that decide whether
    /// deleting a profile's data would take a sibling's login with it. A hidden **profile
    /// directory** is something the user put out of the way, so `Doctor` skips it rather than
    /// reporting it as an orphan.
    ///
    /// An unreadable directory comes back as an empty list rather than an error: both callers
    /// treat "cannot tell" as "nothing to report", and each documents what it does about that.
    ///
    /// The flag is read from the URL rather than from the listing that produced it, so unlike
    /// `.skipsHiddenFiles` it can fail to get an answer — an entry removed between the two
    /// calls, or a directory listable but not stat-able. It keeps the entry in that case, which
    /// for the caller that asks is the harmless direction: one diagnostic too many, rather than
    /// a profile directory silently unexamined.
    func visibleContents(ofDirectoryAt url: URL, skippingFlaggedHidden: Bool = false) -> [URL] {
        let names = (try? contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { url.appendingPathComponent($0, isDirectory: true) }
            .filter {
                guard skippingFlaggedHidden else { return true }
                return (try? $0.resourceValues(forKeys: [.isHiddenKey]))?.isHidden != true
            }
    }
}

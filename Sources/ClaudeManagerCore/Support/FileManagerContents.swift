import Foundation

public extension FileManager {
    /// A directory's visible entries, listed **by path** and rebuilt as URLs under the very
    /// `url` that was passed in.
    ///
    /// The one way this app enumerates a directory, because `contentsOfDirectory(at:)` loses a
    /// path's spelling twice over and both losses reach the user:
    ///
    /// - It **resolves symlinks** in the URLs it hands back, so scanning `/tmp/Apps` returns
    ///   `/private/tmp/Apps/…` — a spelling nothing else in the app derives, while `Profile.id`
    ///   *is* the launcher's path and a marker records whichever spelling its profile was
    ///   created with.
    /// - It **throws `ENOTDIR`** when the directory handed to it is itself a symlink (only the
    ///   final component is not followed), which a `try?` turns into "this directory is empty".
    ///
    /// Hidden entries are dropped, which is what `.skipsHiddenFiles` did for the URL overload:
    /// by name, and by the file system's own hidden flag — `chflags hidden` leaves the name
    /// alone, so the name test cannot see it.
    ///
    /// An unreadable directory comes back as an empty list rather than an error: both callers
    /// treat "cannot tell" as "nothing to report", and each documents what it does about that.
    func visibleContents(ofDirectoryAt url: URL) -> [URL] {
        let names = (try? contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { url.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isHiddenKey]))?.isHidden != true }
    }
}

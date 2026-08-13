import Darwin
import Foundation

/// The file system's "hidden" bit on a launcher bundle — read one way, written another.
///
/// It exists as its own type because writing it the obvious way breaks the launcher.
enum HiddenFlag {
    /// Whether the item is hidden, by either mechanism macOS offers — the `UF_HIDDEN` inode
    /// flag that `chflags hidden` sets, or the Finder-info bit.
    static func isSet(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

    /// Hide the item, preserving whatever other inode flags it carries.
    ///
    /// **Never `URLResourceValues.isHidden` on a bundle.** On a directory that writes a
    /// `com.apple.FinderInfo` extended attribute, and `codesign --verify --strict` rejects a
    /// bundle carrying one outright — *"resource fork, Finder information, or similar detritus
    /// not allowed"* (measured on this platform, not assumed). macOS refuses to execute a
    /// launcher whose signature is broken, so hiding one that way turns it into a bundle that
    /// appears to hang and never open, and Doctor reports the signature as broken. `chflags`
    /// touches the inode alone, which the signature does not span.
    ///
    /// Best-effort: a launcher that ends up visible is a nuisance, and no caller has anything
    /// better to do about a failure than the user re-hiding it.
    static func set(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        _ = chflags(url.path, info.st_flags | UInt32(UF_HIDDEN))
    }
}

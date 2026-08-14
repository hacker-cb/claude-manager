import Darwin
import Foundation

/// Small path/string helpers used across services. Most are pure string work; `canonicalPath`
/// (with the `sameDirectory` built on it), `sameFile` and `spellingOnDisk` are not — they ask
/// the file system, because a symlink, a volume's case folding and the name a volume actually
/// stores are facts about the disk and not about the string. Each of those three answers
/// "no"/`nil` for a path it cannot reach, so a caller that needs the difference between *absent*
/// and *unreachable* has to establish it itself.
public enum PathUtils {
    /// Collapse a leading `$HOME` to `~` for display. Storage always keeps
    /// absolute paths — this is presentation only.
    public static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Expand a leading `~` to the absolute home directory.
    public static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Make `path` absolute: expand a leading `~`, and resolve a still-relative
    /// path against `base` (so it never depends on the process working directory).
    /// An already-absolute path is returned unchanged (standardized).
    public static func absolutePath(_ path: String, relativeTo base: URL) -> String {
        let expanded = expandingTilde(path)
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// The single spelling of a path, used whenever two of them are compared for being the
    /// same place on disk.
    ///
    /// Symlinks are resolved as well as `.`/`..` folded, because the aliases are not exotic:
    /// macOS puts the temporary directory behind `/var → /private/var`, iCloud's "Desktop &
    /// Documents" replaces `~/Documents` with a symlink, and `absolutePath` above only folds
    /// what `standardizingPath` folds — which is *not* symlinks.
    ///
    /// Case is folded exactly as far as the **volume** folds it, because the answer comes from
    /// the file system rather than from a rule stated here: an existing directory resolves to
    /// the name the volume actually stores, so on a case-insensitive one `…/Work` and `…/work`
    /// come back identical, and on a case-sensitive one they stay apart. That is the right
    /// answer for what this is used for — two spellings that open one directory *are* one
    /// directory, and a purge that missed it would delete a sibling's login. Where nothing
    /// exists at the path there is nobody to ask, and the spelling is kept as given.
    ///
    /// **Symlink** folding is made independent of whether the path exists, by resolving the
    /// deepest ancestor that *does*: `resolvingSymlinksInPath` folds `/private/tmp/x` to
    /// `/tmp/x` only while `x` is on disk, and answers the two spellings differently once it
    /// is not — measured, not assumed. `sameDirectory` gates every `update`, `rebuild` and
    /// `remove` (`profileMatchingItsLauncher`, `add(force:)`), so a launcher recording one side
    /// of that alias would pass every gate until the user deleted the data directory by hand,
    /// and then be neither editable nor removable from the app.
    ///
    /// **Case** folding cannot be made independent the same way, and is not claimed to be: the
    /// volume is the only authority on it and can only be asked about a component that exists.
    /// Two spellings differing in case therefore stop comparing equal once the directory is
    /// gone. That residue is deliberate — inventing an answer would mean guessing the volume's
    /// case sensitivity, and guessing it wrong merges two real directories.
    public static func canonicalPath(_ path: String) -> String {
        var missing: [String] = []
        var probe = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            missing.append(probe.lastPathComponent)
            probe = probe.deletingLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    /// Whether two paths name the same directory. Never compare them raw — a profile's
    /// user-data path is free text when the profile is created, so one directory has many
    /// spellings. (Containment is a different question, and `ProfileStore+Remove` owns it.)
    public static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// Whether two paths are **one and the same file** — asked of the file system, because
    /// neither the strings nor `fileExists` can answer it.
    ///
    /// The case that needs it: renaming a launcher to another spelling of its own name.
    /// `…/Work.app` and `…/WORK.app` are one bundle on a case-insensitive volume — macOS's
    /// default — so `fileExists` reports the destination "taken" and what it has found is the
    /// profile's own launcher. On a case-sensitive volume those same two paths are two files,
    /// and a rename must not be allowed to write over the second. The strings are identical in
    /// both worlds; only the volume knows which one it is, so this asks it.
    ///
    /// `canonicalPath` deliberately does **not** cover this. It folds case only as far as an
    /// *existing* directory lets it, and it answers about paths — two spellings of one place.
    /// This answers about the thing at the end of them, which is what a rename acts on.
    ///
    /// `lstat`, so a symlink counts as itself rather than as its target: a launcher and a link
    /// pointing at it are two entries, and treating them as one would have a rename delete the
    /// bundle it was meant to preserve. False whenever either side cannot be statted — a
    /// missing answer is never "yes, the same file", and every caller acts on `true`.
    public static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = fileIdentity(lhs), let right = fileIdentity(rhs) else { return false }
        return left == right
    }

    /// What the file system calls the file at `path` — device and inode — or `nil` when it
    /// cannot be reached. Comparable across time, which is what `sameFile` cannot do: it answers
    /// about two paths *now*, and some questions are about whether the file at one path is still
    /// the one that was there a moment ago.
    public static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// A file's identity as the file system states it — see `fileIdentity`.
    public struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    /// `path` with its last component spelled the way the volume stores it, or `nil` when
    /// nothing there can be read.
    ///
    /// A path that *opens* a file is not the same as the file's name: on a case-insensitive
    /// volume `…/WORK.app` opens the installed `…/Work.app`, and asking `lastPathComponent` only
    /// echoes back what the caller already said. This asks the file system instead.
    ///
    /// It matters wherever a path is an **identity** rather than a way in. `Profile.id` *is*
    /// `appPath` and `build` installs a bundle under the spelling its profile carries, so a
    /// profile holding a path that merely opens the launcher can rename that launcher on its
    /// next write. Only the last component is settled, which is the one that is free text: the
    /// rest comes from `ProfileStoreConfiguration` and is the same string for everyone.
    public static func spellingOnDisk(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let name = (try? url.resourceValues(forKeys: [.nameKey]))?.name else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    /// Escape a literal string so it can be embedded in an extended regular
    /// expression (as consumed by `pgrep -f`) and match itself verbatim. Without
    /// this a `.` in a path would match any character and a `(` would open a group.
    public static func regexEscaped(_ string: String) -> String {
        let specials = Set("\\^$.|?*+()[]{}")
        var out = ""
        out.reserveCapacity(string.count)
        for character in string {
            if specials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Quote a string as a single-quoted POSIX shell literal, safe for arbitrary
    /// content (including embedded single quotes).
    public static func shellSingleQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

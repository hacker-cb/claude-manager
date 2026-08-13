import Foundation

/// Small path/string helpers used across services. All but `canonicalPath` (and the
/// `sameDirectory` built on it) are pure; those two have to ask the file system, since a
/// symlink and a volume's case sensitivity are facts about the disk and not about the string.
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

import Foundation

/// Small path/string helpers used across services. Pure and side-effect free so
/// they are trivially unit-testable.
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

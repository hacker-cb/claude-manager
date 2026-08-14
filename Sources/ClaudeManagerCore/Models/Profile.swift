import Foundation

/// A managed launcher profile: everything needed to (re)build the thin launcher
/// `.app` and to describe it in the UI. Absolute paths only — display collapsing
/// happens at the presentation layer.
public struct Profile: Identifiable, Equatable, Hashable, Sendable {
    /// Short handle, e.g. `work`. Lowercased by convention. Immutable: it is part of the
    /// profile's identity, and an edit that could reach it would rename a profile out from
    /// under everything keyed on it (see `ProfileEdits`).
    public let name: String
    /// Finder/Dock name, e.g. `Claude WORK`. Becomes `CFBundleName`.
    public var displayName: String
    /// Badge text, e.g. `W` or `WK`.
    public var label: String
    /// Badge fill color.
    public var color: BadgeColor
    /// `--user-data-dir` for this profile (absolute path).
    ///
    /// Immutable, and the more load-bearing of the two: this directory holds the profile's
    /// Anthropic login and its chat history, and a launcher pointed somewhere else does not
    /// take them along — it abandons them. Moving profile data is a separate operation that
    /// would have to move the directory and its `-3p` overlay with it; no edit may stand in
    /// for it, so no edit can reach this.
    public let profilePath: String
    /// Launcher `CFBundleIdentifier`.
    public var bundleID: String
    /// Absolute path to the launcher `.app`.
    ///
    /// Immutable for the same reason as the other two, and it is the sharpest of the three:
    /// this is the bundle every operation writes to, trashes, or rebuilds, so a profile
    /// re-pointed at an arbitrary path makes `update` retire whatever sits there and `remove`
    /// trash it. `update` derives its own from the install dir and the validated display name.
    public let appPath: String

    /// Internal on purpose. `let` on the identity fields stops a profile being *mutated* into
    /// pointing somewhere else; this stops one being *fabricated* that way, which is the same
    /// hole by the other door — `update` and `rebuild` both take a profile and build from it,
    /// so a hand-built one with a substituted `profilePath` would rewrite an installed
    /// launcher to abandon its data. Outside this module a `Profile` therefore only ever comes
    /// from where one actually exists: `ProfileStore.draft` or a launcher's own marker.
    init(
        name: String,
        displayName: String,
        label: String,
        color: BadgeColor,
        profilePath: String,
        bundleID: String,
        appPath: String
    ) {
        self.name = name
        self.displayName = displayName
        self.label = label
        self.color = color
        self.profilePath = profilePath
        self.bundleID = bundleID
        self.appPath = appPath
    }

    /// Stable identity: the launcher path is unique within an install directory.
    public var id: String {
        appPath
    }

    public var appURL: URL {
        URL(fileURLWithPath: appPath)
    }

    public var profileURL: URL {
        URL(fileURLWithPath: profilePath)
    }
}

public extension Profile {
    /// `Claude WORK` from `work`.
    static func defaultDisplayName(for name: String) -> String {
        "Claude \(name.uppercased())"
    }

    /// Badge default label derived from the name: the initials (first letter of each
    /// word) when the name is multi-word — split on spaces, dashes, or underscores —
    /// otherwise the leading characters. Capped at `maxLength` (the badge style's
    /// `maxLabelLength`) and stored as-is; casing is applied at render time by
    /// `BadgeStyle.drawnLabel` per the uppercase toggle.
    static func defaultLabel(for name: String, maxLength: Int) -> String {
        let words = name.split { $0 == "-" || $0 == "_" || $0.isWhitespace }
        let token: String = if words.count >= 2 {
            words.compactMap(\.first).map(String.init).joined()
        } else if let word = words.first {
            String(word)
        } else {
            // A non-empty name made only of separators (e.g. "-", "__") is valid but
            // has no words — fall back to the raw name so the label is never blank.
            name
        }
        return String(token.prefix(max(1, maxLength)))
    }

    /// `io.github.hacker-cb.claude-manager.launcher.work`.
    static func defaultBundleID(for name: String) -> String {
        "\(CoreConstants.defaultBundleIDPrefix).\(name.lowercased())"
    }

    /// Reject names that would produce a malformed bundle path or filename.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A display name becomes the launcher's `.app` filename, so it must stay a
    /// single path component — no separators or traversal — to keep the bundle
    /// path inside the install directory. Spaces are allowed (e.g. "Claude WORK").
    static func isValidDisplayName(_ displayName: String) -> Bool {
        guard !displayName.isEmpty, displayName != ".", displayName != ".." else { return false }
        if displayName.hasPrefix(".") { return false }
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        return displayName.rangeOfCharacter(from: forbidden) == nil
    }

    /// Reverse-DNS-ish bundle identifier written to `CFBundleIdentifier`: only
    /// letters, digits, dots and hyphens, at least one dot, and no empty segments.
    static func isValidBundleID(_ bundleID: String) -> Bool {
        guard bundleID.contains("."), !bundleID.hasPrefix("."), !bundleID.hasSuffix("."),
              !bundleID.contains("..")
        else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return bundleID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

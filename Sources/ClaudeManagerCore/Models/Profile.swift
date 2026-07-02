import Foundation

/// A managed launcher profile: everything needed to (re)build the thin launcher
/// `.app` and to describe it in the UI. Absolute paths only — display collapsing
/// happens at the presentation layer.
public struct Profile: Identifiable, Equatable, Hashable, Sendable {
    /// Short handle, e.g. `work`. Lowercased by convention.
    public var name: String
    /// Finder/Dock name, e.g. `Claude WORK`. Becomes `CFBundleName`.
    public var displayName: String
    /// Badge text, e.g. `W` or `WK`.
    public var label: String
    /// Badge fill color.
    public var color: BadgeColor
    /// `--user-data-dir` for this account (absolute path).
    public var profilePath: String
    /// Launcher `CFBundleIdentifier`.
    public var bundleID: String
    /// Absolute path to the launcher `.app`.
    public var appPath: String

    public init(
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

    /// Badge defaults to the first two letters of the name, uppercased.
    static func defaultLabel(for name: String) -> String {
        String(name.prefix(2)).uppercased()
    }

    /// `me.sokolov.claude-manager.launcher.work`.
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
}

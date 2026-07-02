import Foundation

/// Creates, reads, and removes the thin launcher `.app` bundles. The bundle's
/// Info.plist marker is the source of truth; `scan` reconstructs profiles from it.
public struct LauncherBundle {
    let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// A launcher discovered on disk together with its parsed marker.
    public struct Discovered: Equatable, Sendable {
        public let appURL: URL
        public let marker: LauncherMarker
        public let bundleID: String
        public let displayName: String

        /// Reconstruct the full `Profile` from what the bundle stores.
        public var profile: Profile {
            let color = (try? BadgeColor.parse(marker.color)) ?? .named("blue")
            return Profile(
                name: marker.name,
                displayName: displayName,
                label: marker.label,
                color: color,
                profilePath: marker.profile,
                bundleID: bundleID,
                appPath: appURL.path
            )
        }
    }

    // MARK: - Build

    /// (Re)create the launcher bundle for `profile`. Overwrites an existing bundle
    /// at the same path — callers enforce the force/running policy first.
    public func build(profile: Profile, realBinaryPath: String, icnsData: Data) throws {
        let appURL = profile.appURL
        let parent = appURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        // Assemble into a hidden sibling first, then swap it into place — an
        // existing launcher is only removed once the new one is fully written, so
        // a mid-build failure can't leave the user without a working launcher.
        // Same parent dir keeps the final move on one volume (atomic rename).
        let tempURL = parent.appendingPathComponent(".\(appURL.lastPathComponent).build-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempURL) }

        let contents = tempURL.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        // Badge icon.
        try icnsData.write(to: resources.appendingPathComponent("Badge.icns"))

        // Launcher script (executable).
        let script = LauncherScript.render(
            profilePath: profile.profilePath,
            realBinaryPath: realBinaryPath
        )
        let launcher = macOS.appendingPathComponent("launcher")
        try Data(script.utf8).write(to: launcher)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        // Info.plist with the marker.
        let marker = LauncherMarker(
            name: profile.name,
            label: profile.label,
            color: profile.color.storageString,
            profile: profile.profilePath
        )
        try writeInfoPlist(
            at: contents.appendingPathComponent("Info.plist"),
            profile: profile,
            marker: marker
        )

        if fileManager.fileExists(atPath: appURL.path) {
            _ = try fileManager.replaceItemAt(appURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: appURL)
        }
    }

    func writeInfoPlist(at url: URL, profile: Profile, marker: LauncherMarker) throws {
        // NB: deliberately no `CFBundleIconName` — when present macOS reads the icon
        // from Assets.car and ignores our `.icns`.
        let info: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": profile.bundleID,
            "CFBundleName": profile.displayName,
            "CFBundleDisplayName": profile.displayName,
            "CFBundleIconFile": "Badge.icns",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            CoreConstants.markerKey: marker.dictionary
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: - Read

    /// Parse a bundle's marker, or `nil` if it is not one of ours.
    public func readMarker(at appURL: URL) -> Discovered? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = RealClaude.plist(at: infoURL, fileManager: fileManager),
              let markerDict = info[CoreConstants.markerKey] as? [String: Any],
              let marker = LauncherMarker(dictionary: markerDict)
        else { return nil }
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? Profile.defaultBundleID(for: marker.name)
        let displayName = (info["CFBundleName"] as? String) ?? Profile.defaultDisplayName(for: marker.name)
        return Discovered(appURL: appURL, marker: marker, bundleID: bundleID, displayName: displayName)
    }

    public func isManagedLauncher(at appURL: URL) -> Bool {
        readMarker(at: appURL) != nil
    }

    /// All managed launchers directly inside `installDirectory`, sorted by name.
    public func scan(installDirectory: URL) -> [Discovered] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.pathExtension == "app" }
            .compactMap { readMarker(at: $0) }
            .sorted { $0.marker.name.localizedCaseInsensitiveCompare($1.marker.name) == .orderedAscending }
    }

    // MARK: - Remove

    /// Move the launcher to the Trash (recoverable). Returns the trashed URL.
    @discardableResult
    public func moveToTrash(appURL: URL) throws -> URL? {
        var trashed: NSURL?
        try fileManager.trashItem(at: appURL, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// True when a same-named bundle already sits in the Trash — a hint that this
    /// path had a launcher before, so IconServices may hold a stale cached icon.
    /// Also matches Finder's collision renames (`Name 2.app`), since `trashItem`
    /// renames on conflict.
    public func hasTrashedTwin(appURL: URL) -> Bool {
        let trash = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let name = appURL.lastPathComponent
        if fileManager.fileExists(atPath: trash.appendingPathComponent(name).path) {
            return true
        }
        // Scan for a `<base> <n>.<ext>` collision rename when the Trash is listable.
        guard let entries = try? fileManager.contentsOfDirectory(atPath: trash.path) else { return false }
        let base = appURL.deletingPathExtension().lastPathComponent
        let suffix = appURL.pathExtension.isEmpty ? "" : "." + appURL.pathExtension
        return entries.contains { entry in
            guard entry.hasPrefix(base + " "), entry.hasSuffix(suffix) else { return false }
            let middle = entry.dropFirst(base.count + 1).dropLast(suffix.count)
            return !middle.isEmpty && middle.allSatisfy(\.isNumber)
        }
    }
}

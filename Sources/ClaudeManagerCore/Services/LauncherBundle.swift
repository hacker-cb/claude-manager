import CryptoKit
import Darwin
import Foundation

/// Creates, reads, and removes the thin launcher `.app` bundles. The bundle's
/// Info.plist marker is the source of truth; `scan` reconstructs profiles from it.
public struct LauncherBundle {
    let fileManager: FileManager
    let codeSigner: CodeSigner

    public init(fileManager: FileManager = .default, runner: CommandRunner = SystemCommandRunner()) {
        self.fileManager = fileManager
        codeSigner = CodeSigner(runner: runner)
    }

    /// A launcher discovered on disk together with its parsed marker.
    public struct Discovered: Equatable, Sendable {
        public let appURL: URL
        public let marker: LauncherMarker
        public let bundleID: String
        public let displayName: String

        /// The wrapper version stamped into this launcher (older bundles → 1).
        public var wrapperVersion: Int {
            marker.wrapperVersion
        }

        /// True when this launcher was built by an older wrapper than the current
        /// one, so a rebuild would regenerate its script/Info.plist. On its own not an
        /// error — the launcher still runs; it just misses the latest wrapper
        /// improvements. See `isUnrunnable` for the subset that does not run at all.
        public var isStale: Bool {
            CoreConstants.wrapperVersionIsStale(marker.wrapperVersion)
        }

        /// True when this launcher predates ad-hoc signing (wrapper < 3), so macOS
        /// refuses to execute it — a rebuild is mandatory, not an improvement.
        public var isUnrunnable: Bool {
            CoreConstants.wrapperVersionIsUnrunnable(marker.wrapperVersion)
        }

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

    /// What a scan of an install directory found, and whether that is the whole story.
    public struct Scan: Equatable, Sendable {
        public let launchers: [Discovered]
        /// Bundles that could not be read well enough to tell whether they are ours — empty
        /// when the *directory itself* could not be listed, which `isComplete` also covers.
        /// Carried so a caller can name what actually blocked it: "make the launcher folder
        /// readable" is the wrong remedy for a folder that listed fine.
        public let unreadable: [URL]
        /// Whether the directory listed **and** every bundle in it could be read.
        ///
        /// **An incomplete scan must never be read as "nobody claims this profile
        /// directory".** That question decides whether a user-data directory — an Anthropic
        /// login and a whole chat history — is deleted, and `removeItem` is not a Trash move.
        /// A folder that was renamed, unmounted, or had its permissions changed answers it
        /// exactly as an empty one does, and so does a single sibling bundle that cannot be
        /// read.
        public let isComplete: Bool

        public init(launchers: [Discovered], unreadable: [URL], listed: Bool = true) {
            self.launchers = launchers
            self.unreadable = unreadable
            isComplete = listed && unreadable.isEmpty
        }
    }

    // MARK: - Build

    /// The `Contents/Resources` file name carrying `icnsData` — content-addressed, so the
    /// name changes exactly when the icon's bytes do.
    ///
    /// This is what makes an edited badge actually *appear*. A launcher rebuild presents
    /// the same bundle identity every time — same path, same `CFBundleIdentifier`, same
    /// `CFBundleVersion` (we ship a fixed `1`) — so when it also points at the same
    /// `Badge.icns`, IconServices has nothing to tell the new icon apart by and serves the
    /// image it already rendered. The resource name is the one part of that identity this
    /// app controls, so deriving it from the icon's own bytes is what makes an edited badge
    /// a thing the cache has never seen. The staging build always writes into a fresh
    /// directory, so the previous name is dropped with the bundle it belonged to rather
    /// than accumulating.
    ///
    /// `sha256(icns)[:16]` mirrors `TokenProvider.fingerprint`: 64 bits is far past any
    /// practical collision here, and the name stays short enough to read in Finder.
    public static func iconFileName(for icnsData: Data) -> String {
        let hex = SHA256.hash(data: icnsData).map { String(format: "%02x", $0) }.joined()
        return "Badge-\(hex.prefix(16)).icns"
    }

    /// The `Contents/Resources` file name a bundle's recorded `CFBundleIconFile` refers to,
    /// or `nil` when it records nothing usable. The single place that value is interpreted,
    /// so every reader resolves it the same way:
    ///
    /// - `lastPathComponent` keeps the read inside `Contents/Resources`. A launcher bundle
    ///   is user-writable, so the recorded value is not trusted to be a bare file name.
    /// - The extension is optional in `CFBundleIconFile`, so restore it when absent —
    ///   otherwise a hand-written `Badge` resolves to no file at all.
    public static func iconResourceName(recorded: String?) -> String? {
        guard let recorded, !recorded.isEmpty else { return nil }
        var name = (recorded as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        return name
    }

    /// (Re)create the launcher bundle for `profile`. Overwrites an existing bundle
    /// at the same path — callers enforce the force/running policy first. Returns whether
    /// the badge icon actually changed vs. what was installed at this path, so a caller
    /// can skip the screen-flashing Dock refresh when it didn't.
    @discardableResult
    public func build(profile: Profile, realBinaryPath: String, icnsData: Data) throws -> Bool {
        let appURL = profile.appURL
        let iconFileName = Self.iconFileName(for: icnsData)

        // Whether the badge icon changes vs. what's already installed here. A rebuild that
        // leaves the icon untouched (a wrapper-format bump, a script fix) needs no Dock
        // refresh at all; only a real icon change does. A brand-new path has no prior icon
        // and counts as changed — callers pair this with "was a bundle already here" to
        // decide whether a pinned tile could be stale. Compared against the freshly
        // rendered `icnsData`, so a non-deterministic renderer degrades gracefully: the
        // worst case is a redundant refresh hint, never a spurious silent flash.
        let iconChanged = installedIconDiffers(at: appURL, name: iconFileName, data: icnsData)

        // A launcher the user put out of sight (`chflags hidden`, or Finder) stays out of
        // sight across a rebuild. `scan` keeps such bundles deliberately — a hidden launcher
        // still runs and still claims its user-data directory — so `rebuildAll` reaches them,
        // and the swap below writes a fresh directory that carries none of the old one's
        // attributes. Read before the swap, restored after it.
        let wasHidden = HiddenFlag.isSet(at: appURL)

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

        // Badge icon, under its content-addressed name.
        try icnsData.write(to: resources.appendingPathComponent(iconFileName))

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
            marker: marker,
            iconFileName: iconFileName
        )

        // Ad-hoc sign LAST — macOS refuses to execute a launcher that has no valid
        // signature (see `CodeSigner`), and the signature seals the script, the
        // Info.plist and the icon: any write into the bundle after this point breaks it,
        // and a *broken* signature is refused harder than a missing one. So `build`
        // stays the single writer, and nothing may be added below this line.
        //
        // Signing the staging copy rather than the installed path keeps the build
        // atomic: the bundle is swapped into place already sealed, so a launcher is
        // never observable unsigned, and a signing failure leaves the previous working
        // launcher untouched. The signature survives the swap because it lives in
        // `Contents/_CodeSignature/` — ordinary files that move with the directory.
        do {
            try codeSigner.signAdHoc(bundleURL: tempURL)
        } catch let ClaudeManagerError.codeSigningFailed(_, exitCode, message) {
            // Re-anchor the failure on the launcher's real path: the staging directory
            // the signer saw is deleted by the `defer` above before anyone reads the
            // message, and its scrambled name names nothing the user can act on.
            throw ClaudeManagerError.codeSigningFailed(
                path: appURL.path, exitCode: exitCode, message: message
            )
        }

        if fileManager.fileExists(atPath: appURL.path) {
            _ = try fileManager.replaceItemAt(appURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: appURL)
        }
        // Below the signing call, and allowed to be: `HiddenFlag` writes the inode's own flag
        // bits, which the seal does not span — its doc says why the obvious API is not usable
        // here, and that the two are not interchangeable.
        if wasHidden { HiddenFlag.set(at: appURL) }
        return iconChanged
    }

    /// Whether the badge this build is about to write differs from what the bundle
    /// installed at `appURL` presents — by the resource **name** it points at as well as by
    /// its bytes. Both are read from that bundle's own `CFBundleIconFile`, never a
    /// hardcoded name, which is also what keeps this correct against a launcher built
    /// before v4 whose badge is still the fixed `Badge.icns`.
    ///
    /// The name is checked on its own for one case, and it is the case this whole change
    /// exists for: a pre-v4 launcher that was already edited carries the *current* badge
    /// bytes behind a name IconServices has a stale render for. Comparing bytes alone
    /// calls that "unchanged", so the migration rebuild — the very moment the fix reaches
    /// that launcher — would decline to offer the Dock refresh its tile needs. After v4
    /// the name is derived from the bytes, so this adds nothing to an ordinary rebuild:
    /// same icon, same name, still unchanged.
    private func installedIconDiffers(at appURL: URL, name: String, data: Data) -> Bool {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = RealClaude.plist(at: infoURL, fileManager: fileManager),
              let installedName = Self.iconResourceName(recorded: info["CFBundleIconFile"] as? String)
        else { return true } // nothing installed here yet, or unreadable — treat as changed
        guard installedName == name else { return true }
        // Same name still gets a byte check: it catches a truncated or hand-edited
        // resource, where the name promises bytes the file no longer holds.
        let installed = try? Data(
            contentsOf: appURL.appendingPathComponent("Contents/Resources")
                .appendingPathComponent(installedName)
        )
        return installed != data
    }

    func writeInfoPlist(
        at url: URL,
        profile: Profile,
        marker: LauncherMarker,
        iconFileName: String
    ) throws {
        // NB: deliberately no `CFBundleIconName` — when present macOS reads the icon
        // from Assets.car and ignores our `.icns`.
        //
        // `LSArchitecturePriority`: our executable is a bash *script*, not a Mach-O.
        // A script carries no CPU-architecture slice for LaunchServices to read, so on
        // Apple Silicon it brings `/bin/bash` up under Rosetta (x86_64); the script's
        // `exec` of the universal Claude binary then inherits x86_64 and the whole
        // profile runs translated. Declaring a priority makes LaunchServices launch the
        // interpreter native (arm64), so the exec'd Claude is native too. The list is
        // host-relative — on Intel, arm64 is unavailable and x86_64 is used — so the
        // same key is correct on both architectures.
        let info: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": profile.bundleID,
            "CFBundleName": profile.displayName,
            "CFBundleDisplayName": profile.displayName,
            "CFBundleIconFile": iconFileName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSArchitecturePriority": ["arm64", "x86_64"],
            CoreConstants.markerKey: marker.dictionary
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: - Read

    /// Parse a bundle's marker, or `nil` if it is not one of ours.
    public func readMarker(at appURL: URL) -> Discovered? {
        guard case let .launcher(discovered) = read(at: appURL) else { return nil }
        return discovered
    }

    /// What one bundle turned out to be, decided by a **single** read of its `Info.plist`.
    ///
    /// The three outcomes have to come from one read, because the two that mean "not a launcher
    /// of ours" are treated very differently: `foreign` lets a scan call itself complete, and a
    /// complete scan is what licenses deleting a user-data directory. Re-probing after the fact
    /// lets the two answers disagree — permissions or a mount changing in between — and the
    /// disagreement always lands the same way, with the launcher missing from the list while
    /// the scan says it saw everything.
    ///
    /// `unreadable` therefore covers every "cannot establish": an unreachable bundle or plist,
    /// bytes that do not parse, and a marker whose fields are missing or of the wrong type.
    /// Only a plist that parsed and simply carries no marker is `foreign` — an ordinary
    /// third-party app sitting in the install directory.
    func read(at appURL: URL) -> BundleRead {
        // `lstat`, not `fileExists`, because the two failures have to be told apart: an entry
        // that is *gone* is harmless, while one that cannot be statted — the install directory
        // losing traversal, a volume going away — is unknown, and calling it foreign is what
        // licenses deleting the data it may still claim.
        var info = stat()
        guard lstat(appURL.path, &info) == 0 else {
            return errno == ENOENT ? .foreign : .unreadable
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            // A link *to* a launcher is a launcher, so follow it. A link that leads nowhere is
            // **not** treated as a plain non-bundle: an unmounted volume answers `ENOENT`
            // exactly as a dangling link does, and that is the case this whole signal exists
            // for — a launcher on a detached disk still claims its user-data directory.
            guard stat(appURL.path, &info) == 0 else { return .unreadable }
        }
        // Not a directory at all — a Finder alias, a stray file. Not a bundle we failed to
        // read; not a bundle.
        guard info.st_mode & S_IFMT == S_IFDIR else { return .foreign }

        // Everything below is decided by *reading the plist at its known path*, never by
        // enumerating a directory to see whether it is there. A bundle whose directories grant
        // traversal but not listing (mode `0311`) reads perfectly well, and requiring a listing
        // would hide a working launcher from the app entirely while marking every scan
        // incomplete — including the checks that then refuse to delete any profile data.
        let infoPath = appURL.appendingPathComponent("Contents/Info.plist").path
        guard let data = fileManager.contents(atPath: infoPath) else {
            // Absent is an ordinary non-bundle; unreachable is an answer we do not have.
            var probe = stat()
            return lstat(infoPath, &probe) != 0 && errno == ENOENT ? .foreign : .unreadable
        }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = parsed as? [String: Any]
        else { return .unreadable }
        // A missing key is an ordinary third-party app. A key that is *present* but not a
        // dictionary is a launcher of ours with damaged metadata — unreadable, so a purge does
        // not take it for a stranger and delete the data it still claims.
        guard let markerValue = plist[CoreConstants.markerKey] else { return .foreign }
        guard let markerDict = markerValue as? [String: Any],
              let marker = LauncherMarker(dictionary: markerDict)
        else { return .unreadable }
        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? Profile.defaultBundleID(for: marker.name)
        let displayName = (plist["CFBundleName"] as? String) ?? Profile.defaultDisplayName(for: marker.name)
        return .launcher(
            Discovered(appURL: appURL, marker: marker, bundleID: bundleID, displayName: displayName)
        )
    }

    /// One entry's verdict — see `read(at:)`.
    enum BundleRead {
        case launcher(Discovered)
        /// Read successfully, and it is not one of ours.
        case foreign
        /// Could not be established either way. Never counted as "not ours": that is the answer
        /// that lets a purge delete a directory this bundle may still claim.
        case unreadable
    }

    public func isManagedLauncher(at appURL: URL) -> Bool {
        readMarker(at: appURL) != nil
    }

    /// All managed launchers directly inside `installDirectory`, sorted by name.
    ///
    /// Each is reported under **`installDirectory`'s own spelling** of the path, rebuilt from
    /// the directory we were handed rather than taken from what `contentsOfDirectory` returns:
    /// that call resolves symlinks, so scanning `/tmp/Apps` hands back `/private/tmp/Apps/…`
    /// and a launcher acquires a second spelling nothing else in the app uses.
    ///
    /// That is not cosmetic. `Profile.id` **is** `appPath`, and every other path is derived
    /// from `ProfileStoreConfiguration.installDirectory` — so a launcher reached through a
    /// symlinked install directory would carry one identity from `scan` and another from
    /// `draft`, the same bundle listed under two ids. `update` re-derives the bundle path the
    /// second way and compares it against the profile's, so an ordinary edit reads as a rename
    /// onto a path that already exists — its own bundle — and is refused outright; and
    /// `liveRewrite` matches the scanned launcher against the profile's own path, so the
    /// "Restart to apply" nudge silently stops appearing. Rebuilding the URL here keeps the
    /// two sides equal *by construction*, rather than by both happening to normalize the same
    /// way afterwards.
    /// Enumerated through `listedContents(ofDirectoryAt:)`, whose doc comment owns why: one
    /// spelling per launcher, and a symlinked install directory that does not read as empty.
    /// The flagged-hidden filter is deliberately *not* asked for — a hidden launcher still runs
    /// and still claims its user-data directory.
    ///
    /// The result carries whether it is **complete**, because callers ask two different
    /// questions of it. "Show me the launchers" is happy with whatever was found; "does anyone
    /// else use this profile directory" is not, and answering that from a partial list deletes
    /// a login. See `Scan.isComplete`.
    public func scan(installDirectory: URL) -> Scan {
        guard let entries = fileManager.listedContents(ofDirectoryAt: installDirectory) else {
            return Scan(launchers: [], unreadable: [], listed: false)
        }
        var launchers: [Discovered] = []
        var unreadable: [URL] = []
        for url in entries where url.pathExtension == "app" {
            switch read(at: url) {
            case let .launcher(discovered): launchers.append(discovered)
            case .foreign: continue
            case .unreadable: unreadable.append(url)
            }
        }
        return Scan(
            launchers: launchers
                .sorted {
                    $0.marker.name.localizedCaseInsensitiveCompare($1.marker.name) == .orderedAscending
                },
            unreadable: unreadable
        )
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

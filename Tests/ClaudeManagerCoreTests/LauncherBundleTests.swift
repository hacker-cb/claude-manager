import Foundation
import Testing
@testable import ClaudeManagerCore

struct LauncherBundleTests {
    let fm = FileManager.default
    let realBinary = "/Applications/Claude.app/Contents/MacOS/Claude"

    func makeProfile(installDir: URL, name: String = "work", label: String = "W") -> Profile {
        let display = Profile.defaultDisplayName(for: name)
        return Profile(
            name: name,
            displayName: display,
            label: label,
            color: .named("blue"),
            profilePath: "/data/\(name)",
            bundleID: Profile.defaultBundleID(for: name),
            appPath: installDir.appendingPathComponent("\(display).app").path
        )
    }

    @Test
    func readMarkerAndIsManagedRejectNonLauncherApp() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        // A plain .app with an Info.plist but no ClaudeManagerLauncher marker.
        let app = dir.appendingPathComponent("Plain.app")
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Plain"], format: .xml, options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        #expect(bundle.readMarker(at: app) == nil)
        #expect(!bundle.isManagedLauncher(at: app))
        // A path with no bundle at all is likewise not a launcher.
        #expect(bundle.readMarker(at: dir.appendingPathComponent("Nope.app")) == nil)
    }

    @Test
    func buildsExpectedBundleStructure() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        let profile = makeProfile(installDir: dir)
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("icns".utf8))

        let app = URL(fileURLWithPath: profile.appPath)
        let launcher = app.appendingPathComponent("Contents/MacOS/launcher")
        #expect(fm.fileExists(atPath: launcher.path))
        let iconName = LauncherBundle.iconFileName(for: Data("icns".utf8))
        #expect(fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/\(iconName)").path))

        let perms = try fm.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o755)

        let script = try String(contentsOf: launcher, encoding: .utf8)
        #expect(script.contains(realBinary))
    }

    @Test
    func buildReportsWhetherIconChanged() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        let profile = makeProfile(installDir: dir)
        // First build: no prior icon at this path → reported as changed.
        #expect(try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("A".utf8)))
        // Same bytes again → unchanged (a wrapper-format bump / script fix leaves the icon
        // byte-identical, so no Dock refresh is needed).
        #expect(try !bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("A".utf8)))
        // Different bytes → changed.
        #expect(try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("B".utf8)))
    }

    /// The badge resource is named after its own bytes, which is what makes an edited icon
    /// visible at all: IconServices keys its cache on the bundle path, id and version —
    /// all unchanged by a rebuild — so a constant file name leaves every key intact and the
    /// stale image is served on.
    @Test
    func iconResourceIsNamedAfterItsContent() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        let profile = makeProfile(installDir: dir)
        let resources = URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Resources")
        let infoURL = URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Info.plist")

        let blue = Data("blue-badge".utf8)
        let red = Data("red-badge".utf8)
        #expect(LauncherBundle.iconFileName(for: blue) != LauncherBundle.iconFileName(for: red))
        // Deterministic: identical bytes must not churn the name (and thus the cache key).
        #expect(LauncherBundle.iconFileName(for: blue) == LauncherBundle.iconFileName(for: blue))

        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: blue)
        #expect(try #require(RealClaude.plist(at: infoURL))["CFBundleIconFile"] as? String
            == LauncherBundle.iconFileName(for: blue))

        // A colour change renames the resource and repoints CFBundleIconFile at it; the
        // previous file leaves with the bundle it belonged to rather than accumulating.
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: red)
        let redIcon = resources.appendingPathComponent(LauncherBundle.iconFileName(for: red))
        let blueIcon = resources.appendingPathComponent(LauncherBundle.iconFileName(for: blue))
        #expect(fm.fileExists(atPath: redIcon.path))
        #expect(!fm.fileExists(atPath: blueIcon.path))
        #expect(try #require(RealClaude.plist(at: infoURL))["CFBundleIconFile"] as? String
            == LauncherBundle.iconFileName(for: red))
    }

    /// The change check reads the installed bundle's *recorded* `CFBundleIconFile` rather
    /// than a hardcoded name, so a launcher built before v4 — whose badge is still the
    /// fixed `Badge.icns` — is compared against its real icon instead of reading nothing
    /// and reporting every rebuild as an icon change.
    @Test
    func iconChangeIsComparedAgainstAPreV4BundlesOwnIconName() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        let profile = makeProfile(installDir: dir)
        let icns = Data("legacy-badge".utf8)
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: icns)

        // Rewrite the freshly built bundle into the pre-v4 shape: a fixed `Badge.icns`.
        let contents = URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try fm.moveItem(
            at: resources.appendingPathComponent(LauncherBundle.iconFileName(for: icns)),
            to: resources.appendingPathComponent("Badge.icns")
        )
        let infoURL = contents.appendingPathComponent("Info.plist")
        var info = try #require(RealClaude.plist(at: infoURL))
        info["CFBundleIconFile"] = "Badge.icns"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: infoURL)

        // Same badge bytes as the legacy bundle carries → no icon change, no Dock refresh.
        #expect(try !bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: icns))
    }

    @Test
    func writesInfoPlistWithMarkerAndNoIconName() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        try LauncherBundle(runner: stubbedSigningRunner()).build(
            profile: profile,
            realBinaryPath: realBinary,
            icnsData: Data("i".utf8)
        )

        let info = try #require(RealClaude.plist(
            at: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Info.plist")
        ))
        #expect(info["CFBundleExecutable"] as? String == "launcher")
        #expect(info["CFBundleIdentifier"] as? String == profile.bundleID)
        #expect(info["CFBundleName"] as? String == profile.displayName)
        #expect(info["CFBundleIconFile"] as? String == LauncherBundle.iconFileName(for: Data("i".utf8)))
        // CFBundleIconName must be absent, else macOS ignores the .icns.
        #expect(info["CFBundleIconName"] == nil)
        // Force native execution: without this the script-based bundle launches
        // /bin/bash under Rosetta on Apple Silicon, so the exec'd Claude runs x86_64.
        #expect(info["LSArchitecturePriority"] as? [String] == ["arm64", "x86_64"])
        #expect(info[CoreConstants.markerKey] != nil)
    }

    @Test
    func readMarkerReconstructsProfile() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        let discovered = try #require(bundle.readMarker(at: URL(fileURLWithPath: profile.appPath)))
        #expect(discovered.profile.name == "work")
        #expect(discovered.profile.label == "W")
        #expect(discovered.profile.color == .named("blue"))
        #expect(discovered.profile.profilePath == "/data/work")
        #expect(discovered.profile.bundleID == profile.bundleID)
        #expect(discovered.profile.displayName == profile.displayName)
    }

    @Test
    func scanFindsManagedAndIgnoresBareApps() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        try bundle.build(
            profile: makeProfile(installDir: dir),
            realBinaryPath: realBinary,
            icnsData: Data("i".utf8)
        )

        // A plain .app with no marker must be ignored.
        let bare = dir.appendingPathComponent("Random.app/Contents")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        let bareInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Random"], format: .xml, options: 0
        )
        try bareInfo.write(to: bare.appendingPathComponent("Info.plist"))

        let found = bundle.scan(installDirectory: dir)
        #expect(found.map(\.marker.name) == ["work"])
        #expect(bundle.isManagedLauncher(at: URL(fileURLWithPath: makeProfile(installDir: dir).appPath)))
    }

    @Test
    func rebuildOverwritesPreviousMarker() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle(runner: stubbedSigningRunner())
        var profile = makeProfile(installDir: dir, label: "W")
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        profile.label = "ZZ"
        profile.color = .named("red")
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        let discovered = try #require(bundle.readMarker(at: URL(fileURLWithPath: profile.appPath)))
        #expect(discovered.marker.label == "ZZ")
        #expect(discovered.marker.color == "red")
    }
}

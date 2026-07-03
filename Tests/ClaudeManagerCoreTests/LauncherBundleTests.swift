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

        let bundle = LauncherBundle()
        #expect(bundle.readMarker(at: app) == nil)
        #expect(!bundle.isManagedLauncher(at: app))
        // A path with no bundle at all is likewise not a launcher.
        #expect(bundle.readMarker(at: dir.appendingPathComponent("Nope.app")) == nil)
    }

    @Test
    func buildsExpectedBundleStructure() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle()
        let profile = makeProfile(installDir: dir)
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("icns".utf8))

        let app = URL(fileURLWithPath: profile.appPath)
        let launcher = app.appendingPathComponent("Contents/MacOS/launcher")
        #expect(fm.fileExists(atPath: launcher.path))
        #expect(fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Badge.icns").path))

        let perms = try fm.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o755)

        let script = try String(contentsOf: launcher, encoding: .utf8)
        #expect(script.contains(realBinary))
    }

    @Test
    func writesInfoPlistWithMarkerAndNoIconName() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        try LauncherBundle().build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        let info = try #require(RealClaude.plist(
            at: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Info.plist")
        ))
        #expect(info["CFBundleExecutable"] as? String == "launcher")
        #expect(info["CFBundleIdentifier"] as? String == profile.bundleID)
        #expect(info["CFBundleName"] as? String == profile.displayName)
        #expect(info["CFBundleIconFile"] as? String == "Badge.icns")
        // CFBundleIconName must be absent, else macOS ignores the .icns.
        #expect(info["CFBundleIconName"] == nil)
        #expect(info[CoreConstants.markerKey] != nil)
    }

    @Test
    func readMarkerReconstructsProfile() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        let bundle = LauncherBundle()
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
        let bundle = LauncherBundle()
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
        let bundle = LauncherBundle()
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

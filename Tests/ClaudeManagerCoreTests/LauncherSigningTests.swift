import Foundation
import Testing
@testable import ClaudeManagerCore

/// Every path that writes a launcher bundle must leave it ad-hoc signed: macOS refuses
/// to execute an unsigned `.app`, so an unsigned launcher checks in with LaunchServices,
/// shows up in the Dock, and is then killed — the user sees it "hang and never open".
struct LauncherSigningTests {
    let fm = FileManager.default
    let realBinary = "/Applications/Claude.app/Contents/MacOS/Claude"

    private func makeProfile(installDir: URL, name: String = "work", label: String = "W") -> Profile {
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

    // MARK: - LauncherBundle

    @Test
    func buildProducesAValidAdHocSignature() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)

        try LauncherBundle().build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        #expect(SignatureProbe.isValidAdHoc(URL(fileURLWithPath: profile.appPath)))
    }

    /// The rebuild path — `build` over an existing bundle — must re-sign, not inherit
    /// the old signature. This is where a naive "sign only on create" fix regresses.
    @Test
    func rebuildOverAnExistingBundleReSigns() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let bundle = LauncherBundle()
        var profile = makeProfile(installDir: dir, label: "W")
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        profile.label = "ZZ"
        profile.color = .named("red")
        try bundle.build(profile: profile, realBinaryPath: realBinary, icnsData: Data("ii".utf8))

        let appURL = URL(fileURLWithPath: profile.appPath)
        #expect(SignatureProbe.isValidAdHoc(appURL))
        // …and the signature seals the *new* contents, not a stale copy.
        #expect(try #require(bundle.readMarker(at: appURL)).marker.label == "ZZ")
    }

    /// Pins the reason signing must be the last step of `build`: the seal covers the
    /// script and the Info.plist, so any later write into the bundle invalidates it.
    @Test
    func anyWriteIntoASignedBundleInvalidatesIt() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        try LauncherBundle().build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        let appURL = URL(fileURLWithPath: profile.appPath)

        let launcher = appURL.appendingPathComponent("Contents/MacOS/launcher")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: launcher)

        #expect(SignatureProbe.isSigned(appURL))
        #expect(!SignatureProbe.isValidAdHoc(appURL))
    }

    /// Signing happens on the staging copy, before the swap — so a signing failure
    /// aborts the build with the previous (working, signed) launcher still in place.
    @Test
    func signingFailureLeavesThePreviousLauncherIntact() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        var profile = makeProfile(installDir: dir, label: "W")
        try LauncherBundle().build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))

        profile.label = "ZZ"
        #expect(throws: ClaudeManagerError.self) {
            try LauncherBundle(runner: failingCodesignRunner())
                .build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        }

        let appURL = URL(fileURLWithPath: profile.appPath)
        #expect(SignatureProbe.isValidAdHoc(appURL))
        #expect(try #require(LauncherBundle().readMarker(at: appURL)).marker.label == "W")
    }

    @Test
    func signingFailureOnAFirstBuildLeavesNoBundleBehind() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)

        #expect(throws: ClaudeManagerError.self) {
            try LauncherBundle(runner: failingCodesignRunner())
                .build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        }

        #expect(!fm.fileExists(atPath: profile.appPath))
        // No staging leftovers either — the hidden build dir is cleaned up.
        let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: - ProfileStore mutation paths

    @Test
    func addProducesASignedLauncher() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }

        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile

        #expect(SignatureProbe.isValidAdHoc(URL(fileURLWithPath: profile.appPath)))
    }

    @Test
    func updateKeepsTheLauncherSignedAcrossARename() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        defer { Fixture.purgeTrash(displayNamePrefix: env.display("work")) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile

        var edited = profile
        edited.displayName = env.display("work") + " Renamed"
        edited.color = .named("red")
        let updated = try env.store.update(original: profile, to: edited)

        #expect(SignatureProbe.isValidAdHoc(URL(fileURLWithPath: updated.appPath)))
    }

    @Test
    func rebuildAllReSignsEveryLauncher() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let one = try env.store.add(AddProfileRequest(name: env.name("one"))).profile
        let two = try env.store.add(AddProfileRequest(name: env.name("two"))).profile

        let result = try env.store.rebuildAll()

        #expect(result.rebuilt.count == 2)
        #expect(SignatureProbe.isValidAdHoc(URL(fileURLWithPath: one.appPath)))
        #expect(SignatureProbe.isValidAdHoc(URL(fileURLWithPath: two.appPath)))
    }
}

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

    /// The reported failure must name the launcher the user asked for — not the hidden
    /// staging directory the signer saw, which is deleted before the message is read.
    @Test
    func signingFailureNamesTheLauncherNotTheStagingCopy() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)

        var reported: ClaudeManagerError?
        do {
            try LauncherBundle(runner: failingCodesignRunner())
                .build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        } catch let error as ClaudeManagerError {
            reported = error
        }

        guard case let .codeSigningFailed(path, exitCode, _) = try #require(reported) else {
            Issue.record("expected codeSigningFailed, got \(String(describing: reported))")
            return
        }
        #expect(path == profile.appPath)
        #expect(exitCode == 1)
    }

    /// A `codesign` that never ran has no exit status, so none is invented for it.
    @Test
    func aCodesignThatCannotRunIsNotReportedWithAnExitCode() throws {
        var reported: ClaudeManagerError?
        do {
            try CodeSigner(runner: UnrunnableToolRunner())
                .signAdHoc(bundleURL: URL(fileURLWithPath: "/tmp/x.app"))
        } catch let error as ClaudeManagerError {
            reported = error
        }

        guard case let .codeSigningFailed(_, exitCode, message) = try #require(reported) else {
            Issue.record("expected codeSigningFailed, got \(String(describing: reported))")
            return
        }
        #expect(exitCode == nil)
        #expect(message.contains("no such tool"))
        // …and the rendered message says so instead of naming a fabricated status.
        let description = try #require(reported?.errorDescription)
        #expect(description.contains("could not be run"))
        #expect(!description.contains("exited"))
    }

    /// `codesign --verify` is what actually gates execution, so the signer can report on
    /// an existing bundle — `Doctor` uses this to catch a launcher whose seal is broken.
    @Test
    func isValidlySignedTracksTheOnDiskSeal() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let profile = makeProfile(installDir: dir)
        try LauncherBundle().build(profile: profile, realBinaryPath: realBinary, icnsData: Data("i".utf8))
        let signer = CodeSigner(runner: SystemCommandRunner())
        let appURL = URL(fileURLWithPath: profile.appPath)
        #expect(signer.isValidlySigned(bundleURL: appURL))

        try Data("#!/bin/bash\nexit 0\n".utf8)
            .write(to: appURL.appendingPathComponent("Contents/MacOS/launcher"))

        #expect(!signer.isValidlySigned(bundleURL: appURL))
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

    /// A launcher macOS refuses to run must not be reported through the soft "stale"
    /// channel that means "misses the latest improvements" — Doctor calls it an error,
    /// and does not also emit the optional-sounding warning for the same bundle.
    @Test
    func doctorReportsAnUnsignedLauncherAsAnError() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try setWrapperVersion(CoreConstants.minimumRunnableWrapperVersion - 1, atAppPath: profile.appPath)

        let diagnostics = env.store.doctor()

        #expect(diagnostics.contains {
            $0.severity == .error && $0.title.contains("unsigned — macOS will not run it")
        })
        #expect(!diagnostics.contains { $0.title.contains("older launcher format") })
    }

    /// A current-format launcher whose seal was broken after the build is invisible to
    /// every other check — its script, marker and profile dir are all intact — so the
    /// signature check is the only thing standing between the user and a dead launcher.
    @Test
    func doctorReportsABrokenSealAsAnError() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(!env.store.doctor().contains { $0.severity == .error })

        try Data("#!/bin/bash\nexit 0\n".utf8).write(
            to: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/MacOS/launcher")
        )

        #expect(env.store.doctor().contains {
            $0.severity == .error && $0.title.contains("signature is broken")
        })
    }

    /// A failed add must not leave the profile dir it created behind — Doctor would
    /// then report an orphan the user never made.
    @Test
    func addRollsBackTheProfileDirectoryWhenSigningFails() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // Stop delegating `codesign` to the real system so it can be made to fail.
        env.runner.setDelegated([CoreConstants.iconutilPath])
        env.runner.setHandler { executable, arguments in
            if executable == CoreConstants.codesignPath {
                return CommandOutput(exitCode: 1, standardOutput: "", standardError: "refused")
            }
            return idleStub(executable, arguments)
        }

        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work")))
        }

        let profilePath = env.profilesDir.appendingPathComponent(env.name("work")).path
        #expect(!fm.fileExists(atPath: profilePath))
        #expect(!env.store.doctor().contains { $0.title.contains("Orphan profile") })
    }

    /// `rebuildAll` must carry *why* each launcher failed: a signing failure leaves the
    /// launcher unable to start, and a bare list of names gives the user nothing to act on.
    @Test
    func rebuildAllKeepsTheReasonForEachFailure() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        env.runner.setDelegated([CoreConstants.iconutilPath])
        env.runner.setHandler { executable, arguments in
            if executable == CoreConstants.codesignPath {
                return CommandOutput(exitCode: 1, standardOutput: "", standardError: "refused by policy")
            }
            return idleStub(executable, arguments)
        }

        let result = try env.store.rebuildAll()

        let failure = try #require(result.failed.first)
        #expect(failure.profile.name == env.name("work"))
        #expect(failure.reason.contains("sign"))
        #expect(failure.reason.contains("refused by policy"))
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

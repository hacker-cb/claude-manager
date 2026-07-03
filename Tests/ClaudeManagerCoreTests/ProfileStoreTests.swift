import Foundation
import Testing
@testable import ClaudeManagerCore

struct ProfileStoreTests {
    let fm = FileManager.default

    @Test
    func addCreatesLauncherAndProfileDir() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        let result = try env.store.add(AddProfileRequest(
            name: env.name("work"),
            label: "W",
            color: .named("green")
        ))

        #expect(!result.reusedProfileData)
        #expect(fm.fileExists(atPath: result.profile.appPath))
        #expect(fm.fileExists(atPath: result.profile.profilePath))

        let listed = env.store.list()
        #expect(listed.map(\.profile.name) == [env.name("work")])
        #expect(listed[0].isRunning == false)

        // The generated badge is a genuine .icns.
        let icns = try Data(contentsOf: URL(fileURLWithPath: result.profile.appPath)
            .appendingPathComponent("Contents/Resources/Badge.icns"))
        #expect(icns.prefix(4) == Data("icns".utf8))

        // A brand-new bundle (no trashed twin) must not restart the Dock.
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    @Test
    func addReusesExistingProfileData() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profileDir = env.profilesDir.appendingPathComponent(env.name("work"))
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: profileDir.appendingPathComponent("session"))

        let result = try env.store.add(AddProfileRequest(name: env.name("work")))
        #expect(result.reusedProfileData)
    }

    @Test
    func addRejectsDuplicateWithoutForce() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work")))
        }
    }

    @Test
    func addRejectsInvalidName() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: "has space"))
        }
    }

    @Test
    func addRejectsInvalidBundleID() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work"), bundleID: "no dots here"))
        }
    }

    @Test
    func addRejectsInstallDirectoryThatIsAFile() throws {
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let fileAsInstallDir = root.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: fileAsInstallDir)
        let real = try Fixture.makeFakeRealApp(in: root, iconData: Fixture.baseICNSData())
        let store = ProfileStore(
            realClaude: real,
            configuration: ProfileStoreConfiguration(
                installDirectory: fileAsInstallDir,
                defaultProfilesDirectory: root.appendingPathComponent("profiles")
            ),
            runner: RecordingCommandRunner.delegating(stub: idleStub),
            signalSender: { _, _ in 0 }
        )
        #expect(throws: ClaudeManagerError.self) {
            try store.add(AddProfileRequest(name: "work"))
        }
    }

    @Test
    func addRefusedWhileProfileRunning() throws {
        // The profile's user-data-dir already has a live instance → refuse
        // regardless of force (guards against rebuilding under a running process).
        let env = try makeEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "999\n", standardError: "")
            }
            return idleStub(executable, args)
        })
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work")))
        }
    }

    @Test
    func addRejectsTraversalDisplayName() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work"), displayName: "../../../Evil"))
        }
        #expect(!fm.fileExists(atPath: env.root.appendingPathComponent("Evil.app").path))
    }

    @Test
    func updateRejectsTraversalDisplayName() throws {
        let env = try makeEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var evil = original
        evil.displayName = "../../../Evil"
        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(original: original, to: evil)
        }
    }

    @Test
    func removeKeepsDataSharedByAnotherLauncher() throws {
        let env = try makeEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"), profilePath: shared)).profile
        _ = try env.store.add(AddProfileRequest(name: env.name("bb"), profilePath: shared)).profile

        let result = try env.store.remove(first, purgeProfile: true)
        // The second launcher still points at the shared dir, so its data is kept.
        #expect(!result.purgedProfileData)
        #expect(fm.fileExists(atPath: shared))
    }

    @Test
    func draftUsesDefaults() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        let draft = env.store.draft(name: "work")
        #expect(draft.displayName == "Claude WORK")
        #expect(draft.label == "wo") // raw casing; uppercased at render by BadgeStyle.drawnLabel
        #expect(draft.appPath == env.installDir.appendingPathComponent("Claude WORK.app").path)
        #expect(draft.profilePath == env.profilesDir.appendingPathComponent("work").path)
        #expect(draft.bundleID == "io.github.hacker-cb.claude-manager.launcher.work")
    }

    @Test
    func draftNormalizesRelativeProfilePath() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A relative path must resolve against the profiles dir, never the CWD.
        let draft = env.store.draft(name: "work", profilePath: "relative/data")
        #expect(draft.profilePath.hasPrefix("/"))
        #expect(draft.profilePath == env.profilesDir.appendingPathComponent("relative/data").path)
    }

    @Test
    func openInvokesOpenWithNewInstanceFlag() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try env.store.open(profile)
        let call = try #require(env.runner.invocations(of: CoreConstants.openPath).last)
        #expect(call.arguments == ["-n", profile.appPath])
    }

    @Test
    func stopReturnsNotRunningWhenAbsent() async throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(await env.store.stop(profile, force: false) == .notRunning)
    }

    @Test
    func stopReturnsStoppedWhenProcessDisappears() async throws {
        let counter = CallCounter()
        let env = try makeEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath {
                // Running on the first probe, gone thereafter.
                let output = counter.next() == 1 ? "555\n" : ""
                return CommandOutput(
                    exitCode: output.isEmpty ? 1 : 0,
                    standardOutput: output,
                    standardError: ""
                )
            }
            return idleStub(executable, args)
        })
        defer { try? fm.removeItem(at: env.root) }
        let profile = env.store.draft(name: env.name("work"))
        let outcome = await env.store.stop(profile, force: false, pollInterval: 0.01, maxPolls: 10)
        #expect(outcome == .stopped)
    }

    @Test
    func stopHonorsCancellationWithoutBusySpinning() async throws {
        // pgrep always reports the same live pid, so stop can never see it exit and
        // would poll its whole budget. A huge interval + budget means a
        // cancellation-aware loop returns right after the first (cancelled) sleep,
        // having probed at most a couple of times — a swallowed CancellationError
        // would instead spin `maxPolls` rapid pgrep probes.
        let env = try makeEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "777\n", standardError: "")
            }
            return idleStub(executable, args)
        })
        defer { try? fm.removeItem(at: env.root) }
        let profile = env.store.draft(name: env.name("work"))

        // Build the store inside the task from Sendable inputs so nothing
        // non-Sendable is captured across the task boundary (Swift 6 mode).
        let real = env.real
        let runner = env.runner
        let config = ProfileStoreConfiguration(
            installDirectory: env.installDir,
            defaultProfilesDirectory: env.profilesDir
        )
        let task = Task {
            let store = ProfileStore(
                realClaude: real, configuration: config, runner: runner,
                signalSender: { _, _ in 0 }
            )
            return await store.stop(profile, force: false, pollInterval: 100, maxPolls: 1000)
        }
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .stillRunning(pid: 777))
        // The initial guard probes once; cancellation must not spin the remaining
        // budget doing hundreds more probes.
        #expect(env.runner.invocations(of: CoreConstants.pgrepPath).count <= 3)
    }

    @Test
    func removeTrashesLauncherAndPurgesData() throws {
        let env = try makeEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: true)

        #expect(!fm.fileExists(atPath: profile.appPath))
        #expect(!fm.fileExists(atPath: profile.profilePath))
        #expect(result.purgedProfileData)
    }

    @Test
    func removeKeepsDataByDefault() throws {
        let env = try makeEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: false)
        #expect(!result.purgedProfileData)
        #expect(fm.fileExists(atPath: profile.profilePath))
    }

    @Test
    func removeThrowsWhenLauncherMissing() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A profile whose launcher was never built → consistent domain error.
        let ghost = env.store.draft(name: env.name("ghost"))
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(ghost, purgeProfile: false)
        }
    }

    @Test
    func removeRejectsRunning() throws {
        let env = try makeEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "999\n", standardError: "")
            }
            return idleStub(executable, args)
        })
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = env.store.draft(name: env.name("work"))
        try LauncherBundle().build(
            profile: profile,
            realBinaryPath: env.real.binaryURL.path,
            icnsData: Data("i".utf8)
        )
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(profile, purgeProfile: false)
        }
    }

    @Test
    func updateRenamesLauncherAndTrashesOld() throws {
        let env = try makeEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("job"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var updated = original
        updated.displayName = env.display("job")
        updated.label = "JB"
        updated.color = .named("red")
        updated.appPath = env.appPath("job")

        _ = try env.store.update(original: original, to: updated)
        #expect(!fm.fileExists(atPath: original.appPath))
        #expect(fm.fileExists(atPath: updated.appPath))

        let discovered = try #require(LauncherBundle().readMarker(at: URL(fileURLWithPath: updated.appPath)))
        #expect(discovered.marker.label == "JB")
        #expect(discovered.marker.color == "red")
    }

    @Test
    func regenerateAllIconsRestartsDockOnce() throws {
        let env = try makeEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        _ = try env.store.add(AddProfileRequest(name: env.name("home")))
        let rebuilt = try env.store.regenerateAllIcons()
        #expect(Set(rebuilt.map(\.name)) == [env.name("work"), env.name("home")])
        // Exactly one Dock restart for the whole batch (fresh bundles don't restart).
        #expect(env.runner.invocations(of: CoreConstants.killallPath).count == 1)
    }
}

/// Preconditions shared by the mutating `ProfileStore` entry points, kept in their
/// own suite so `ProfileStoreTests` stays under the body-length cap.
struct ProfileStorePreconditionTests {
    @Test
    func mutationsRejectMissingRealBinary() throws {
        // With the wrapped Claude binary absent, every mutation that bakes its path
        // into a launcher (`add`, `update`) or reads its icon (`regenerateIcon`)
        // fails fast with the same domain error. `open` is intentionally exempt — it
        // never references `realClaude`.
        let fm = FileManager.default
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let missingReal = RealClaude(appURL: root.appendingPathComponent("Missing.app"))
        #expect(!missingReal.binaryExists())
        let store = ProfileStore(
            realClaude: missingReal,
            configuration: ProfileStoreConfiguration(
                installDirectory: root.appendingPathComponent("apps"),
                defaultProfilesDirectory: root.appendingPathComponent("profiles")
            ),
            runner: RecordingCommandRunner.delegating(stub: idleStub),
            signalSender: { _, _ in 0 }
        )
        let profile = store.draft(name: "work")

        #expect(throws: ClaudeManagerError.realClaudeNotFound) {
            try store.add(AddProfileRequest(name: "work"))
        }
        #expect(throws: ClaudeManagerError.realClaudeNotFound) {
            try store.update(original: profile, to: profile)
        }
        #expect(throws: ClaudeManagerError.realClaudeNotFound) {
            try store.regenerateIcon(for: profile)
        }
    }
}

// MARK: - Shared test environment

/// A store wired to temp directories and a fake real app, shared across the
/// ProfileStore suites. Kept at file scope so no single suite's body grows unwieldy;
/// `private` so the generic name can't collide elsewhere in the test target.
private struct Env {
    let root: URL
    let installDir: URL
    let profilesDir: URL
    let real: RealClaude
    let runner: RecordingCommandRunner
    let store: ProfileStore
    /// Per-test token so trashed launchers never collide across the shared
    /// `~/.Trash` (Swift Testing runs tests in parallel).
    let token: String

    func name(_ base: String) -> String {
        base + token
    }

    func display(_ base: String) -> String {
        Profile.defaultDisplayName(for: name(base))
    }

    func appPath(_ base: String) -> String {
        installDir.appendingPathComponent("\(display(base)).app").path
    }
}

/// `iconutil` runs for real (so icons are genuine `.icns`); every other tool is
/// stubbed, so no process is killed and the Dock is never restarted for real.
private func makeEnv(stub: @escaping @Sendable (String, [String]) -> CommandOutput = idleStub) throws -> Env {
    let fm = FileManager.default
    let root = try Fixture.makeTempDir()
    let installDir = root.appendingPathComponent("apps")
    let profilesDir = root.appendingPathComponent("profiles")
    try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
    let real = try Fixture.makeFakeRealApp(in: root, iconData: Fixture.baseICNSData())
    let runner = RecordingCommandRunner.delegating(stub: stub)
    let store = ProfileStore(
        realClaude: real,
        configuration: ProfileStoreConfiguration(
            installDirectory: installDir,
            defaultProfilesDirectory: profilesDir
        ),
        runner: runner,
        signalSender: { _, _ in 0 }
    )
    let token = String(UUID().uuidString.prefix(8)).lowercased().replacingOccurrences(of: "-", with: "")
    return Env(
        root: root, installDir: installDir, profilesDir: profilesDir,
        real: real, runner: runner, store: store, token: token
    )
}

import Foundation
import Testing
@testable import ClaudeManagerCore

struct ProfileStoreTests {
    let fm = FileManager.default

    @Test
    func addCreatesLauncherAndProfileDir() throws {
        let env = try makeStoreEnv()
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
        let icns = try Fixture.installedBadgeData(inLauncherAt: result.profile.appPath)
        #expect(icns.prefix(4) == Data("icns".utf8))

        // A brand-new bundle (no trashed twin) must not restart the Dock.
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    @Test
    func addReusesExistingProfileData() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profileDir = env.profilesDir.appendingPathComponent(env.name("work"))
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: profileDir.appendingPathComponent("session"))

        let result = try env.store.add(AddProfileRequest(name: env.name("work")))
        #expect(result.reusedProfileData)
    }

    @Test
    func addRejectsDuplicateWithoutForce() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work")))
        }
    }

    @Test
    func addRejectsInvalidName() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: "has space"))
        }
    }

    @Test
    func addRejectsInvalidBundleID() throws {
        let env = try makeStoreEnv()
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
        let env = try makeStoreEnv(stub: { executable, args in
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
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work"), displayName: "../../../Evil"))
        }
        #expect(!fm.fileExists(atPath: env.root.appendingPathComponent("Evil.app").path))
    }

    @Test
    func updateRejectsTraversalDisplayName() throws {
        let env = try makeStoreEnv()
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
    func draftUsesDefaults() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let draft = env.store.draft(name: "work")
        #expect(draft.displayName == "Claude WORK")
        // 3 leading chars (default style maxLabelLength = 3), raw casing; uppercased at
        // render by BadgeStyle.drawnLabel.
        #expect(draft.label == "wor")
        #expect(draft.appPath == env.installDir.appendingPathComponent("Claude WORK.app").path)
        #expect(draft.profilePath == env.profilesDir.appendingPathComponent("work").path)
        #expect(draft.bundleID == "io.github.hacker-cb.claude-manager.launcher.work")
    }

    @Test
    func draftNormalizesRelativeProfilePath() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A relative path must resolve against the profiles dir, never the CWD.
        let draft = env.store.draft(name: "work", profilePath: "relative/data")
        #expect(draft.profilePath.hasPrefix("/"))
        #expect(draft.profilePath == env.profilesDir.appendingPathComponent("relative/data").path)
    }

    @Test
    func openInvokesOpenWithNewInstanceFlag() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try env.store.open(profile)
        let call = try #require(env.runner.invocations(of: CoreConstants.openPath).last)
        #expect(call.arguments == ["-n", profile.appPath])
    }

    @Test
    func stopReturnsNotRunningWhenAbsent() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        #expect(await env.store.stop(profile, force: false) == .notRunning)
    }

    @Test
    func stopReturnsStoppedWhenProcessDisappears() async throws {
        let counter = CallCounter()
        let env = try makeStoreEnv(stub: { executable, args in
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
        let env = try makeStoreEnv(stub: { executable, args in
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
        // A cancelled stop must not spin the remaining budget doing hundreds of probes:
        // it settles in a bounded handful (guard + `poll`'s pre-check and post-break
        // recheck), not `maxPolls`.
        #expect(env.runner.invocations(of: CoreConstants.pgrepPath).count <= 4)
    }

    @Test
    func updateRenamesLauncherAndTrashesOld() throws {
        let env = try makeStoreEnv()
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

    /// A rename whose Trash step fails is undone, not left half-applied.
    ///
    /// The alternative — keeping the new bundle and reporting the stray old one — leaves two
    /// launchers on one user-data dir, which the app reads as deliberate everywhere else: the
    /// stale bundle stays in the sidebar as an ordinary row, `runningPID` lights up both rows
    /// with one pid, and `liveRewrite` drops the restart nudge because ownership is ambiguous.
    @Test
    func updateUndoesARenameWhoseTrashStepFails() throws {
        // No `purgeTrash` cleanup: this store refuses every `trashItem`, so nothing of its
        // making ever reaches the Trash.
        let env = try makeStoreEnv(fileManager: TrashRefusingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let originalColor = try #require(LauncherBundle().readMarker(at: original.appURL)).marker.color
        var updated = original
        updated.displayName = env.display("job")
        updated.color = .named("red")

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.update(original: original, to: updated)
        }

        // The old launcher is untouched and the new one was rolled back, so the install
        // directory holds exactly the launcher it started with.
        #expect(fm.fileExists(atPath: original.appPath))
        #expect(!fm.fileExists(atPath: env.appPath("job")))
        #expect(env.store.list().count == 1)
        // And it still carries the badge it had — the edit did not land halfway.
        let discovered = try #require(LauncherBundle().readMarker(at: original.appURL))
        #expect(discovered.marker.color == originalColor)

        // The message names the bundle to deal with, says the edit was undone, and carries
        // the filesystem's own reason. It must *not* tell the user to trash that launcher:
        // after the rollback it is the profile's only one.
        let message = try #require(thrown.errorDescription)
        #expect(message.contains(PathUtils.abbreviatingHome(original.appPath)))
        #expect(message.contains(TrashRefusingFileManager.message))
        #expect(message.contains("The edit was undone"))
        #expect(!message.contains("Move the first to the Trash"))
    }

    /// The race the rollback must not lose to: the old bundle is removed by something else
    /// between the existence check and the Trash attempt. Retiring it is what the failed step
    /// was *for*, so the rename stands — undoing it here would delete the profile's only
    /// remaining launcher and leave it with none.
    @Test
    func updateKeepsTheRenameWhenTheOldLauncherVanishedMidTrash() throws {
        let env = try makeStoreEnv(fileManager: TrashVanishingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var updated = original
        updated.displayName = env.display("job")

        let result = try env.store.update(original: original, to: updated)

        #expect(result.profile.displayName == env.display("job"))
        #expect(fm.fileExists(atPath: env.appPath("job")))
        #expect(!fm.fileExists(atPath: original.appPath))
        #expect(env.store.list().count == 1)
    }

    @Test
    func rebuildAllDefersDockRefreshAndNeverFlashes() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        _ = try env.store.add(AddProfileRequest(name: env.name("home")))
        let result = try env.store.rebuildAll()
        #expect(Set(result.rebuilt.map(\.name)) == [env.name("work"), env.name("home")])
        #expect(result.liveRewrites.isEmpty)
        #expect(result.failed.isEmpty)
        // Rebuilding unchanged launchers regenerates byte-identical badges, so nothing is
        // pending and the screen-flashing Dock restart is never issued (opt-in only).
        #expect(result.dockRefreshPending == false)
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }
}

/// Preconditions shared by the mutating `ProfileStore` entry points, kept in their
/// own suite so `ProfileStoreTests` stays under the body-length cap.
struct ProfileStorePreconditionTests {
    @Test
    func mutationsRejectMissingRealBinary() throws {
        // With the wrapped Claude binary absent, every mutation that bakes its path
        // into a launcher (`add`, `update`, `rebuild`) fails fast with the same domain
        // error. `open` is intentionally exempt — it never references `realClaude`.
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
            try store.rebuild(profile)
        }
    }
}

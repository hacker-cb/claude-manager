import Foundation
import Testing
@testable import ClaudeManagerCore

/// One launcher has one path — and `Profile.id` *is* that path, so a second spelling of it is
/// a second identity. `contentsOfDirectory` resolves symlinks, so an install directory reached
/// through one is where the two spellings appear; these hold `scan` to the spelling it was
/// asked with.
///
/// Separate file/suite so no single test file grows past the length cap; shares `makeStoreEnv`
/// with the other ProfileStore suites.
struct LauncherPathSpellingTests {
    let fm = FileManager.default

    /// The fixtures of `makeStoreEnv`, plus a second store reaching the *same* install
    /// directory by another spelling.
    private struct LinkedEnv {
        let env: StoreEnv
        let installDir: URL
        let store: ProfileStore
    }

    /// A store whose install directory is reached *through* a symlinked parent — `/tmp/Apps`,
    /// where `/tmp` is the link. The link is one level up, not on the directory itself:
    /// `contentsOfDirectory` refuses a symlink handed to it directly, so that arrangement
    /// produces an empty scan rather than the second spelling under test here.
    private func makeLinkedEnv() throws -> LinkedEnv {
        let env = try makeStoreEnv()
        let link = env.root.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: env.root)
        let installDir = link.appendingPathComponent(env.installDir.lastPathComponent)
        return LinkedEnv(env: env, installDir: installDir, store: store(in: env, installDir: installDir))
    }

    /// The same fixtures, reached through another spelling of the install directory. Every
    /// hermetic field `makeStoreEnv` sets is carried over, so this store reads no host state.
    private func store(in env: StoreEnv, installDir: URL) -> ProfileStore {
        ProfileStore(
            realClaude: env.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: installDir,
                defaultProfilesDirectory: env.profilesDir,
                managedPreferencesURLs: env.managedPreferencesURLs,
                defaultProfileUserDataPath: env.defaultProfileUserDataPath,
                shipItStatePath: env.shipItStatePath
            ),
            runner: env.runner,
            signalSender: { _, _ in 0 }
        )
    }

    /// The launcher `list` reports and the launcher `add` returned must be one profile, not
    /// two. They differ only in how the path is spelled, and `Profile.id` is that path — so a
    /// mismatch splits one bundle into two sidebar rows, each with its own selection state.
    @Test
    func scanReportsLaunchersUnderTheSpellingItWasAskedWith() throws {
        let linked = try makeLinkedEnv()
        let (env, installDir, store) = (linked.env, linked.installDir, linked.store)
        defer { try? fm.removeItem(at: env.root) }
        let added = try store.add(AddProfileRequest(name: env.name("work"))).profile

        let listed = try #require(store.list().first).profile

        #expect(listed.id == added.id)
        #expect(listed.appPath == installDir.appendingPathComponent("\(env.display("work")).app").path)
        // The bundle itself is one bundle — both spellings reach it.
        #expect(fm.fileExists(atPath: env.appPath("work")))
    }

    /// The app edits the profile it got from `list`, and `update` re-derives the bundle path
    /// from the configuration — so the two spellings meet here. Read as a rename, the edit
    /// would find the new path "already taken" by the profile's own bundle and be refused, and
    /// the restart nudge would go with it: `liveRewrite` matches the scanned launcher against
    /// this same path.
    @Test
    func anEditOfAListedProfileSurvivesASymlinkedInstallDirectory() throws {
        let linked = try makeLinkedEnv()
        let (env, store) = (linked.env, linked.store)
        defer { try? fm.removeItem(at: env.root) }
        let added = try store.add(AddProfileRequest(name: env.name("work"))).profile
        // Gated on the profile's own spelling, the way the real anchored pattern is: an
        // unconditional stub would answer a probe aimed at *any* path, so the pid assertion
        // below would survive `liveRewrite` probing with a spelling no launcher ever execs.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                let mine = args.last?
                    .contains(PathUtils.regexEscaped(added.profilePath) + "( |$)") == true
                return mine
                    ? CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
                    : CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
            return idleStub(executable, args)
        }
        let listed = try #require(store.list().first).profile
        var edits = ProfileEdits(listed)
        edits.label = "ZZ"

        let result = try store.update(listed, applying: edits)

        #expect(result.profile.appPath == listed.appPath)
        #expect(LauncherBundle().readMarker(at: result.profile.appURL)?.marker.label == "ZZ")
        // Still exactly one launcher: the edit was applied in place, not treated as a rename.
        #expect(store.list().count == 1)
        // And the nudge survives — the running window still shows the badge it launched with.
        #expect(result.liveRewrite?.pid == 888)
    }

    /// The restart nudge is withheld when two launchers share a user-data directory, because
    /// the pid could be either one's — and a sibling holding *another spelling* of that
    /// directory counts, even though `mainPID`'s anchored pattern would not have matched an
    /// instance launched from it. That pattern only settles ownership while a launcher's
    /// script and its marker agree, and nothing re-checks them after `build` writes the two:
    /// a hand-edited marker leaves an instance that answers this probe behind a marker that
    /// no longer matches this string. Withholding costs a badge that stays stale until the
    /// window is reopened; getting it wrong costs someone's live session to a Restart.
    @Test
    func aSiblingSpellingTheProfileDirDifferentlyBlocksTheNudge() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("one"))
            Fixture.purgeTrash(displayNamePrefix: env.display("two"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        // `PathUtils.absolutePath` standardizes but does not resolve symlinks, so this second
        // spelling survives into the sibling's marker exactly as typed.
        let sharedLink = env.profilesDir.appendingPathComponent("shared-link")
        try fm.createSymbolicLink(at: sharedLink, withDestinationURL: shared)

        let one = try env.store.add(
            AddProfileRequest(name: env.name("one"), profilePath: shared.path)
        ).profile
        let two = try env.store.add(
            AddProfileRequest(name: env.name("two"), profilePath: sharedLink.path)
        ).profile
        #expect(two.profilePath != one.profilePath) // same directory, two spellings

        // The stub answers only the probe carrying `one`'s spelling — all the real, anchored
        // pattern would match. So `one` is genuinely running, and the nudge is withheld anyway:
        // the point is that `pgrep` telling the two apart is not the same as ownership being
        // provable.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                let mine = args.last?
                    .contains(PathUtils.regexEscaped(one.profilePath) + "( |$)") == true
                return mine
                    ? CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
                    : CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
            return idleStub(executable, args)
        }
        var edits = ProfileEdits(one)
        edits.label = "ZZ"
        let result = try env.store.update(one, applying: edits)

        // The edit lands; only the nudge is withheld.
        #expect(result.liveRewrite == nil)
        #expect(LauncherBundle().readMarker(at: result.profile.appURL)?.marker.label == "ZZ")
    }

    /// An install directory that *is* a symlink — Settings → Launcher folder pointed at one,
    /// or a Claude.app living in one. `contentsOfDirectory(at:)` throws `ENOTDIR` on it and
    /// `scan` swallows that as "no launchers", which reaches the user as an empty sidebar
    /// while every launcher still sits on disk and still opens.
    @Test
    func launchersAreFoundWhenTheInstallDirectoryIsItselfASymlink() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let link = env.root.appendingPathComponent("apps-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: env.installDir)
        let linkedStore = store(in: env, installDir: link)

        let added = try linkedStore.add(AddProfileRequest(name: env.name("work"))).profile

        let listed = linkedStore.list()
        #expect(listed.count == 1)
        #expect(listed.first?.profile.id == added.id)
    }

    /// Doctor enumerates the *profiles* directory the same way, and a marker records whichever
    /// spelling the profile was created with. Through a symlinked parent — iCloud's "Desktop &
    /// Documents" turns `~/Documents` into one, and the profiles folder is user-settable —
    /// Foundation's resolved entry paths matched no marker at all, so every live profile was
    /// reported as an orphan: a directory holding the user's login, named as safe to delete.
    @Test
    func doctorDoesNotCallALiveProfileAnOrphanUnderASymlinkedProfilesDir() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        let link = scene.root.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: scene.root)
        let profilesDir = link.appendingPathComponent(scene.profilesDir.lastPathComponent)
        let profileDir = profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try buildDoctorLauncher(in: scene, name: "work", profileDir: profileDir)
        let runner = RecordingCommandRunner(handler: idleStub)

        let diagnostics = Doctor(
            realClaude: scene.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: scene.installDir,
                defaultProfilesDirectory: profilesDir,
                defaultProfileUserDataPath: scene.defaultProfilePath,
                shipItStatePath: scene.shipItStatePath
            ),
            bundle: LauncherBundle(runner: runner),
            codeSigner: CodeSigner(runner: runner),
            processProbe: ProcessProbe(runner: runner),
            managedConfigWriter: ManagedConfigWriter(
                fileManager: fm, managedPreferencesURLs: scene.noMDM
            )
        ).run()

        #expect(!diagnostics.contains { $0.title == "Orphan profile (no launcher)" })
    }
}

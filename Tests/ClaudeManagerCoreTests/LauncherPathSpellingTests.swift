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

    /// The same fixtures, reached through another spelling of the install directory. Built by
    /// copying the store's own configuration and replacing that one field, so every hermetic
    /// path `makeStoreEnv` wires up is carried over — and stays carried over when it wires up
    /// one more.
    private func store(in env: StoreEnv, installDir: URL) -> ProfileStore {
        var configuration = env.store.configuration
        configuration.installDirectory = installDir
        return ProfileStore(
            realClaude: env.real,
            configuration: configuration,
            runner: env.runner,
            signalSender: { _, _ in 0 }
        )
    }

    /// A `pgrep` stub answering only the probe that carries `profilePath` — what the real,
    /// anchored pattern matches. An unconditional stub would answer a probe aimed at any path,
    /// leaving the tests below asserting nothing about which one was probed.
    private func pgrepStub(
        matching profilePath: String,
        pid: Int32 = 888
    ) -> @Sendable (String, [String]) -> CommandOutput {
        { executable, args in
            guard executable == CoreConstants.pgrepPath else { return idleStub(executable, args) }
            let mine = args.last?
                .contains(PathUtils.regexEscaped(profilePath) + "( |$)") == true
            return mine
                ? CommandOutput(exitCode: 0, standardOutput: "\(pid)\n", standardError: "")
                : CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
        }
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
        env.runner.setHandler(pgrepStub(matching: added.profilePath))
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

        // `one` is genuinely running — the stub answers its probe and no other — and the nudge
        // is withheld anyway: `pgrep` telling the two launchers apart is not the same thing as
        // ownership being provable.
        env.runner.setHandler(pgrepStub(matching: one.profilePath))
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

    /// A launcher carrying the file system's hidden flag (`chflags hidden`, which leaves the
    /// name alone) stays in the scan. `.skipsHiddenFiles` used to drop it, and dropping it is
    /// the dangerous direction: the bundle still runs and still claims its user-data
    /// directory, so out of the scan it is also out of the checks that decide whether deleting
    /// one profile's data would take a sibling's login with it.
    @Test
    func aLauncherHiddenByTheFileSystemStaysInTheScan() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let added = try env.store.add(AddProfileRequest(name: env.name("work"))).profile

        var url = added.appURL
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)

        #expect(env.store.list().map(\.profile.id) == [added.id])
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
        // A genuine orphan beside it, so "no orphan reported" cannot pass by the enumeration
        // coming back empty — which is the other half of the same bug.
        try fm.createDirectory(
            at: profilesDir.appendingPathComponent("ghost"), withIntermediateDirectories: true
        )

        let diagnostics = runDoctor(
            scene,
            runner: RecordingCommandRunner(handler: idleStub),
            profilesDirectory: profilesDir
        )

        let orphans = diagnostics
            .filter { $0.title == "Orphan profile (no launcher)" }
            .compactMap(\.detail)
        #expect(orphans.count == 1)
        #expect(orphans.first?.hasSuffix("/ghost") == true)
    }
}

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
        let store = ProfileStore(
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
        return LinkedEnv(env: env, installDir: installDir, store: store)
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
        _ = try store.add(AddProfileRequest(name: env.name("work")))
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
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

    /// Two launchers may share a user-data directory, and the second one's path is free text,
    /// so it can hold another spelling of the first one's. `runningPID` matches on that
    /// directory, so a pid found while rewriting one launcher may be the other's — and a
    /// string comparison that misses the sibling reports sole ownership and offers a Restart
    /// that stops the sibling's live session.
    @Test
    func aSiblingSpellingTheProfileDirDifferentlyStillBlocksTheNudge() throws {
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

        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        var edits = ProfileEdits(one)
        edits.label = "ZZ"
        let result = try env.store.update(one, applying: edits)

        // The edit lands; only the nudge is withheld, because pid 888 may be the sibling's.
        #expect(result.liveRewrite == nil)
        #expect(LauncherBundle().readMarker(at: result.profile.appURL)?.marker.label == "ZZ")
    }
}

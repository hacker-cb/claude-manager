import Foundation
import Testing
@testable import ClaudeManagerCore

/// `remove` — trashing a launcher and deciding what happens to the data behind it.
/// Separate file/suite so no single test file grows past the length cap, mirroring
/// `ProfileStore+Remove.swift`; shares `makeStoreEnv` with the other ProfileStore suites.
struct ProfileStoreRemoveTests {
    let fm = FileManager.default

    /// The `-3p` overlay path for a profile — the sibling `remove` sweeps alongside the data.
    private func tier(_ profile: Profile) -> URL {
        ManagedConfigWriter.localTierURL(forUserDataPath: profile.profilePath)
    }

    @Test
    func removeTrashesLauncherAndPurgesData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: true)

        #expect(!fm.fileExists(atPath: profile.appPath))
        #expect(!fm.fileExists(atPath: profile.profilePath))
        #expect(result.profileData == .purged)
        // A removal that did exactly what was asked says nothing.
        #expect(result.profileData.notice(forRemovalOf: profile.displayName) == nil)
    }

    @Test
    func removeKeepsDataByDefault() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let result = try env.store.remove(profile, purgeProfile: false)
        #expect(result.profileData == .notRequested)
        #expect(result.profileData.notice(forRemovalOf: profile.displayName) == nil)
        #expect(fm.fileExists(atPath: profile.profilePath))
    }

    @Test
    func removeKeepsDataSharedByAnotherLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"), profilePath: shared)).profile
        let second = try env.store.add(AddProfileRequest(name: env.name("bb"), profilePath: shared)).profile

        let result = try env.store.remove(first, purgeProfile: true)
        // The second launcher still points at the shared dir, so its data is kept.
        #expect(result.profileData == .keptSharedWith(launchers: [second.displayName]))
        #expect(fm.fileExists(atPath: shared))
        // The overlay belongs to that surviving launcher too, so the sweep must not reach it.
        // Nothing else covers this: the only other overlay-survival test runs `purgeProfile:
        // false`, a different branch — and hoisting the sweep above the refusal (the natural
        // move for "always clean the overlay") would strip the survivor's `disableAutoUpdates`
        // and let Claude's own updater run inside the clone, with the suite still green.
        #expect(fm.fileExists(atPath: tier(first).path))
        // The refusal is correct; being quiet about it is not. The user asked to delete a
        // login and it is still on disk, so the notice has to name what is holding it.
        let notice = try #require(result.profileData.notice(forRemovalOf: first.displayName))
        #expect(notice.message.contains(first.displayName))
        #expect(notice.message.contains(second.displayName))
        #expect(notice.title == "Profile data was kept")
    }

    /// Two holders, produced by `remove` itself rather than a hand-built enum value — the
    /// plural wording is otherwise only ever exercised against a literal.
    @Test
    func removeNamesEveryLauncherHoldingTheData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            for name in ["aa", "bb", "cc"] {
                Fixture.purgeTrash(displayNamePrefix: env.display(name))
            }
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"), profilePath: shared)).profile
        let second = try env.store.add(AddProfileRequest(name: env.name("bb"), profilePath: shared)).profile
        let third = try env.store.add(AddProfileRequest(name: env.name("cc"), profilePath: shared)).profile

        let result = try env.store.remove(first, purgeProfile: true)
        let notice = try #require(result.profileData.notice(forRemovalOf: first.displayName))
        #expect(notice.message.contains("\(second.displayName) and \(third.displayName)"))
        #expect(notice.message.contains("those launchers"))
    }

    /// A launcher whose data sits *inside* the one being purged. `removeItem` is recursive, so
    /// without a containment check this deletes that profile's Anthropic token and chat
    /// history and reports a plain success.
    ///
    /// Refused up front rather than half-done: this is the one refusal the user cannot recover
    /// from afterwards, since purging the inner launcher would leave the outer directory
    /// behind with no launcher left to offer deleting it.
    @Test
    func removeRefusesToPurgeAFolderHoldingAnotherLaunchersData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inner"))
        }
        let outerPath = env.profilesDir.appendingPathComponent("tree").path
        let innerPath = URL(fileURLWithPath: outerPath).appendingPathComponent("inner").path
        let outer = try env.store
            .add(AddProfileRequest(name: env.name("outer"), profilePath: outerPath)).profile
        _ = try env.store
            .add(AddProfileRequest(name: env.name("inner"), profilePath: innerPath)).profile
        let keep = URL(fileURLWithPath: innerPath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: keep)

        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(outer, purgeProfile: true)
        }
        // Nothing happened — the launcher is still here to retry through.
        #expect(fm.fileExists(atPath: outer.appPath))
        #expect(fm.fileExists(atPath: keep.path))
        #expect(fm.fileExists(atPath: outerPath))

        // The non-destructive removal is unaffected: it takes only the launcher.
        let kept = try env.store.remove(outer, purgeProfile: false)
        #expect(kept.profileData == .notRequested)
        #expect(fm.fileExists(atPath: keep.path))
    }

    /// The mirror case: purging the *inner* launcher is allowed. The outer one survives and
    /// its own purge can still reach this directory later, so nothing becomes unreachable.
    @Test
    func removePurgesAFolderNestedInsideAnothersData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inner"))
        }
        let outerPath = env.profilesDir.appendingPathComponent("tree").path
        let innerPath = URL(fileURLWithPath: outerPath).appendingPathComponent("inner").path
        let outer = try env.store
            .add(AddProfileRequest(name: env.name("outer"), profilePath: outerPath)).profile
        let inner = try env.store
            .add(AddProfileRequest(name: env.name("inner"), profilePath: innerPath)).profile

        let result = try env.store.remove(inner, purgeProfile: true)

        // Declined, because deleting it is the outer profile's business — but reported, and
        // the outer launcher is still there to do it.
        #expect(result.profileData == .keptSharedWith(launchers: [outer.displayName]))
        #expect(fm.fileExists(atPath: innerPath))
        #expect(fm.fileExists(atPath: outer.appPath))
    }

    /// Shared *and* already deleted out of band. The refusal is still right — nothing is
    /// removed — but saying "your login was kept" names credentials that are not there and
    /// sends the user to remove another launcher for nothing.
    @Test
    func removeReportsAlreadyGoneWhenTheSharedFolderIsMissing() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"), profilePath: shared)).profile
        _ = try env.store.add(AddProfileRequest(name: env.name("bb"), profilePath: shared)).profile
        try fm.removeItem(atPath: shared)

        let result = try env.store.remove(first, purgeProfile: true)
        #expect(result.profileData == .alreadyGone)
        #expect(result.profileData.notice(forRemovalOf: first.displayName) == nil)
        // Still shared, so the overlay is still the survivor's — the sweep stays away.
        #expect(fm.fileExists(atPath: tier(first).path))
    }

    /// The default profile owns no launcher, so it is in no scan and none of the sharing
    /// checks can see it — while pointing a clone at its directory to reuse an existing login
    /// is a supported thing to do. Purging there would delete Claude's own login and history.
    @Test
    func removeRefusesToPurgeTheDefaultProfilesData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("clone"))
        }
        let defaultData = URL(fileURLWithPath: env.defaultProfileUserDataPath)
        try fm.createDirectory(at: defaultData, withIntermediateDirectories: true)
        let token = defaultData.appendingPathComponent("token")
        try Data("primary login".utf8).write(to: token)
        let clone = try env.store.add(AddProfileRequest(
            name: env.name("clone"), profilePath: defaultData.path
        )).profile

        let result = try env.store.remove(clone, purgeProfile: true)

        #expect(result.profileData == .keptForDefaultProfile)
        #expect(fm.fileExists(atPath: defaultData.path))
        #expect(fm.fileExists(atPath: token.path))
        #expect(!fm.fileExists(atPath: clone.appPath)) // the launcher itself did go
        let notice = try #require(result.profileData.notice(forRemovalOf: clone.displayName))
        #expect(notice.message.contains("sign you out of Claude itself"))
    }

    /// Pointing at the default profile's directory when that directory is already gone is
    /// "nothing to delete", not "your login was kept" — and the message for the second would
    /// promise data that is not there. The default profile's `-3p` tier is Claude's own config
    /// and must survive either way.
    @Test
    func removeReportsAlreadyGoneWhenTheDefaultProfilesDataIsMissing() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("clone"))
        }
        let defaultData = URL(fileURLWithPath: env.defaultProfileUserDataPath)
        try fm.createDirectory(at: defaultData, withIntermediateDirectories: true)
        let clone = try env.store.add(AddProfileRequest(
            name: env.name("clone"), profilePath: defaultData.path
        )).profile
        let tier = ManagedConfigWriter.localTierURL(forUserDataPath: defaultData.path)
        try fm.removeItem(at: defaultData) // deleted by hand, after the clone was made

        let result = try env.store.remove(clone, purgeProfile: true)

        #expect(result.profileData == .alreadyGone)
        #expect(result.profileData.notice(forRemovalOf: clone.displayName) == nil)
        // Claude's own config tier is not ours to sweep.
        #expect(fm.fileExists(atPath: tier.path))
    }

    /// A purge that cannot complete. The launcher is already in the Trash by then, so this
    /// must not throw: a thrown error reports the whole removal as failed while half of it
    /// happened, and the half that did not is the half holding the credentials. Skipped
    /// rather than failed under root, which ignores the permission bits it relies on.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user to make a directory undeletable"))
    func removeReportsAFailedPurgeInsteadOfThrowing() throws {
        let env = try makeStoreEnv()
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let parent = env.profilesDir.path
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        // `removeItem` needs write permission on the *parent* to unlink the directory.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)

        let result = try env.store.remove(profile, purgeProfile: true)

        #expect(!fm.fileExists(atPath: profile.appPath)) // the launcher did go to the Trash
        #expect(fm.fileExists(atPath: profile.profilePath)) // the data did not
        guard case let .purgeFailed(reason) = result.profileData else {
            Issue.record("expected purgeFailed, got \(result.profileData)")
            return
        }
        #expect(!reason.isEmpty)
        let notice = try #require(result.profileData.notice(forRemovalOf: profile.displayName))
        #expect(notice.title == "Profile data wasn't deleted")
        #expect(notice.message.contains(reason))
    }

    @Test
    func purgeSpares3pSiblingThatIsAnotherLaunchersData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("sibling"))
        }
        // Pathological but reachable: launcher B's user-data dir is literally launcher A's
        // `-3p` overlay path. Purging A must delete A's data + overlay but spare B's data.
        let workPath = env.profilesDir.appendingPathComponent("work").path
        let siblingPath = workPath + "-3p"
        let work = try env.store
            .add(AddProfileRequest(name: env.name("work"), profilePath: workPath)).profile
        _ = try env.store
            .add(AddProfileRequest(name: env.name("sibling"), profilePath: siblingPath)).profile
        try fm.createDirectory(atPath: siblingPath, withIntermediateDirectories: true, attributes: nil)
        let keep = URL(fileURLWithPath: siblingPath).appendingPathComponent("data")
        try Data("keep".utf8).write(to: keep)

        let result = try env.store.remove(work, purgeProfile: true)

        // B's data dir (== A's `-3p` path) belongs to another launcher, so it is spared.
        #expect(fm.fileExists(atPath: siblingPath))
        #expect(fm.fileExists(atPath: keep.path))
        // B points at A's *overlay* path, not at A's data dir, so it does not hold A's data
        // back: this is a purge that went through, not a refusal.
        #expect(result.profileData == .purged)
    }

    @Test
    func removeThrowsWhenLauncherMissing() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A profile whose launcher was never built → consistent domain error.
        let ghost = env.store.draft(name: env.name("ghost"))
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(ghost, purgeProfile: false)
        }
    }

    @Test
    func removeRejectsRunning() throws {
        let env = try makeStoreEnv(stub: { executable, args in
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
        try LauncherBundle(runner: stubbedSigningRunner()).build(
            profile: profile,
            realBinaryPath: env.real.binaryURL.path,
            icnsData: Data("i".utf8)
        )
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(profile, purgeProfile: false)
        }
    }
}

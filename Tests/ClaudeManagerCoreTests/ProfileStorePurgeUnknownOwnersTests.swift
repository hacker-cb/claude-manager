import Foundation
import Testing
@testable import ClaudeManagerCore

/// A purge may only delete a user-data directory when it could establish that nobody else
/// uses it — and "could not establish" looks exactly like "nobody else does" from the inside:
/// an unlistable launcher folder comes back as no launchers at all. These hold that
/// distinction.
///
/// Separate file/suite so `ProfileStorePurgeSpellingTests` stays within the length cap.
struct ProfileStorePurgeUnknownOwnersTests {
    let fm = FileManager.default

    /// A launcher reached through a symlink in the install directory is still a launcher, and
    /// still claims its user-data directory. Dropping it as "not one of ours" would leave it
    /// out of a scan that nonetheless called itself complete — and the purge would then delete
    /// the data it shares.
    @Test
    func aLauncherReachedThroughASymlinkStillClaimsItsData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("one"))
            Fixture.purgeTrash(displayNamePrefix: env.display("two"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let one = try env.store.add(
            AddProfileRequest(name: env.name("one"), profilePath: shared.path)
        ).profile
        let two = try env.store.add(
            AddProfileRequest(name: env.name("two"), profilePath: shared.path)
        ).profile
        let login = shared.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)
        // The sibling now lives outside the install directory, reached by a link inside it.
        let moved = env.root.appendingPathComponent("moved.app")
        try fm.moveItem(atPath: two.appPath, toPath: moved.path)
        try fm.createSymbolicLink(
            at: URL(fileURLWithPath: two.appPath), withDestinationURL: moved
        )

        let result = try env.store.remove(one, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [two.displayName]))
        #expect(fm.fileExists(atPath: login.path))
    }

    /// "The data is not there" and "the data cannot be reached" answer `fileExists` the same
    /// way, and only one of them means nothing is at stake. Skipping the nested refusal on an
    /// unmounted volume trashes the launcher, reports `.alreadyGone` — which says nothing —
    /// and leaves the inner profile's data undeletable through the app once it is back.
    @Test
    func nestedProfilesAreRefusedEvenWhenTheDataDirectoryIsUnreachable() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inner"))
        }
        let outer = env.profilesDir.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        let innerProfile = try env.store.add(
            AddProfileRequest(name: env.name("inner"), profilePath: inner.path)
        ).profile
        // Gone from the app's reach — what an unmounted volume looks like from here.
        try fm.removeItem(at: outer)

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(outerProfile, purgeProfile: true)
        }

        #expect(fm.fileExists(atPath: outerProfile.appPath))
        #expect(try #require(thrown.errorDescription).contains(innerProfile.displayName))
    }

    /// A sibling seen before the launcher was trashed still claims its directory when the
    /// second read cannot see it — a bundle that lost its permissions in between, a volume that
    /// went away. Forgetting it there is how its data gets deleted.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func aSiblingSeenBeforeTrashingStillCountsAfterwards() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("one"))
            Fixture.purgeTrash(displayNamePrefix: env.display("two"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let one = try env.store.add(
            AddProfileRequest(name: env.name("one"), profilePath: shared.path)
        ).profile
        let two = try env.store.add(
            AddProfileRequest(name: env.name("two"), profilePath: shared.path)
        ).profile
        let login = shared.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)
        // `trashItem` is what runs between the two scans, so making the sibling unreadable
        // there reproduces the window without any timing.
        let fileManager = SiblingHidingFileManager(hideOnTrash: two.appPath)
        let store = ProfileStore(
            realClaude: env.real,
            configuration: env.store.configuration,
            runner: env.runner,
            fileManager: fileManager,
            signalSender: { _, _ in 0 }
        )
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: two.appPath) }

        let result = try store.remove(one, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [two.displayName]))
        #expect(fm.fileExists(atPath: login.path))
    }

    /// An unlistable launcher folder makes the scan report no launchers, which is what an empty
    /// folder reports too. Reading that as "nobody else claims this data" is how a sibling's
    /// login gets deleted over a folder that was merely renamed or unmounted.
    ///
    /// The data is kept and the user is told, while the launcher itself is still removed —
    /// refusing the whole removal would leave a profile that cannot be retired at all.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func purgeKeepsTheDataWhenTheLauncherFolderCannotBeRead() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let login = URL(fileURLWithPath: profile.profilePath).appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)
        // Listable no more, but still traversable — so the launcher is still reachable by path
        // and the removal gets as far as deciding what to do about the data.
        try fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: env.installDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.installDir.path)
        }

        let result = try env.store.remove(profile, purgeProfile: true)

        // The data survives, and the notice says so — an unlistable folder is "cannot tell",
        // and "cannot tell" never deletes.
        #expect(result.profileData == .keptOwnersUnknown)
        #expect(fm.fileExists(atPath: login.path))
        let notice = try #require(result.profileData.notice(forRemovalOf: profile.displayName))
        #expect(notice.message.contains("still on disk"))
    }

    /// The same folder becoming unreadable *after* that pre-flight check — the residue the
    /// guard inside the purge covers. Nothing is deleted there either, and the message stops
    /// short of a remedy through the app, since by then the launcher is already in the Trash.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func aFolderThatBecomesUnreadableMidRemovalStillSparesTheData() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let login = URL(fileURLWithPath: profile.profilePath).appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)
        // `trashItem` is what runs between the two checks, so revoking the listing there
        // reproduces the race without any timing.
        let fileManager = ListingRevokingFileManager(revokeListingOf: env.installDir.path)
        let store = ProfileStore(
            realClaude: env.real,
            configuration: env.store.configuration,
            runner: env.runner,
            fileManager: fileManager,
            signalSender: { _, _ in 0 }
        )
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.installDir.path)
        }

        let result = try store.remove(profile, purgeProfile: true)

        #expect(result.profileData == .keptOwnersUnknown)
        #expect(fm.fileExists(atPath: login.path))
        let notice = try #require(result.profileData.notice(forRemovalOf: profile.displayName))
        #expect(notice.message.contains("still on disk"))
    }
}

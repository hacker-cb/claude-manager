import Foundation
import Testing
@testable import ClaudeManagerCore

/// A purge may only delete a user-data directory when it could establish that nobody else
/// uses it — and "could not establish" looks exactly like "nobody else does" from the
/// inside: an unlistable launcher folder, or a bundle in it that cannot be read, both come
/// back as no launchers at all. These hold that distinction.
///
/// Separate file/suite so `ProfileStorePurgeSpellingTests` stays within the length cap.
struct ProfileStorePurgeUnknownOwnersTests {
    let fm = FileManager.default

    /// A sibling whose bundle cannot be read drops out of the scan the same way a third-party
    /// app does — `readMarker` returns `nil` for both — so an install directory that lists fine
    /// can still yield an answer that is missing the very launcher that would have stopped the
    /// deletion.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func purgeDeclinesWhenASiblingBundleCannotBeRead() throws {
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
        // The sibling is on disk and still claims the directory — it just cannot be read.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: two.appPath)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: two.appPath) }

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(one, purgeProfile: true)
        }

        #expect(fm.fileExists(atPath: one.appPath))
        #expect(fm.fileExists(atPath: login.path))
        // Named by what actually blocked it — the sibling's bundle, not the folder, which
        // lists perfectly well.
        let message = try #require(thrown.errorDescription)
        #expect(message.contains("could not be read"))
        #expect(message.contains(URL(fileURLWithPath: two.appPath).lastPathComponent))
    }

    /// An unlistable launcher folder makes the scan report no launchers, which is what an empty
    /// folder reports too. Reading that as "nobody else claims this data" is how a sibling's
    /// login gets deleted over a folder that was merely renamed or unmounted.
    ///
    /// Refused **before** the launcher is trashed, like the nested case and for the same
    /// reason: afterwards no profile lists that directory any more, so nothing in the app could
    /// offer to delete it and every message would name a remedy the user cannot follow. Stopping
    /// here leaves "make the folder readable and try again" as the whole fix.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func purgeIsRefusedUpFrontWhenTheLauncherFolderCannotBeRead() throws {
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

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(profile, purgeProfile: true)
        }

        // Nothing happened: the launcher is where it was, and so is the login.
        #expect(fm.fileExists(atPath: profile.appPath))
        #expect(fm.fileExists(atPath: login.path))
        let message = try #require(thrown.errorDescription)
        #expect(message.contains("could not be read"))
        #expect(message.contains("Nothing was removed"))
        // The folder is what blocked it here, so the folder is what gets named.
        #expect(message.contains(URL(fileURLWithPath: env.installDir.path).lastPathComponent))
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

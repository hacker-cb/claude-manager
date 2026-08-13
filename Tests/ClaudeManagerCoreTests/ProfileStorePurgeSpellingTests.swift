import Foundation
import Testing
@testable import ClaudeManagerCore

/// A purge decides what to delete by asking which *other* launchers use the directory — and a
/// profile's user-data path is free text, so the same directory reaches those comparisons under
/// more than one spelling. Every case here ends in `removeItem`, which is recursive and not a
/// Trash move, so a comparison that misses a sibling destroys its Anthropic login and its whole
/// chat history with no way back and no message.
///
/// Separate file/suite so `ProfileStoreRemoveTests` stays within the length cap; shares
/// `makeStoreEnv` with the other ProfileStore suites.
struct ProfileStorePurgeSpellingTests {
    let fm = FileManager.default

    /// A symlinked parent, which is how a second spelling reaches a marker: `absolutePath`
    /// standardizes what it is given but does not resolve symlinks, so the path survives into
    /// the launcher's marker exactly as typed.
    private func linkedProfilesDir(_ env: StoreEnv) throws -> URL {
        let link = env.root.appendingPathComponent("profiles-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: env.profilesDir)
        return link
    }

    /// Two launchers on one directory, spelled two ways. The sharing check must see the sibling
    /// and decline, naming it — otherwise the sibling stays in the sidebar, still opens, and
    /// opens signed out and empty.
    @Test
    func purgeDeclinesWhenASiblingSpellsTheSameDirectoryDifferently() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("one"))
            Fixture.purgeTrash(displayNamePrefix: env.display("two"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let sharedByLink = try linkedProfilesDir(env).appendingPathComponent("shared")

        let one = try env.store.add(
            AddProfileRequest(name: env.name("one"), profilePath: shared.path)
        ).profile
        let two = try env.store.add(
            AddProfileRequest(name: env.name("two"), profilePath: sharedByLink.path)
        ).profile
        #expect(two.profilePath != one.profilePath) // one directory, two spellings
        let login = shared.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)

        let result = try env.store.remove(one, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [two.displayName]))
        #expect(fm.fileExists(atPath: login.path))
        let notice = try #require(result.profileData.notice(forRemovalOf: one.displayName))
        #expect(notice.message.contains(two.displayName))
    }

    /// The nested case, and the one `remove` refuses *before* trashing anything: afterwards the
    /// outer launcher is in the Trash, so nothing in the app can offer to finish the job.
    @Test
    func purgeRefusesUpFrontWhenANestedProfileIsSpelledThroughALink() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inner"))
        }
        let outer = env.profilesDir.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let innerByLink = try linkedProfilesDir(env)
            .appendingPathComponent("outer").appendingPathComponent("inner")

        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        let innerProfile = try env.store.add(
            AddProfileRequest(name: env.name("inner"), profilePath: innerByLink.path)
        ).profile
        let login = inner.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(outerProfile, purgeProfile: true)
        }

        // Refused before anything happened: both launchers and both directories are intact.
        #expect(fm.fileExists(atPath: outerProfile.appPath))
        #expect(fm.fileExists(atPath: login.path))
        let message = try #require(thrown.errorDescription)
        #expect(message.contains(innerProfile.displayName))
    }

    /// The overlay sweep deletes a whole directory, so its "is this actually another launcher's
    /// data" guard has to recognise that launcher under whatever spelling it recorded.
    @Test
    func purgeSparesA3pSiblingSpelledThroughALink() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("sibling"))
        }
        let work = env.profilesDir.appendingPathComponent("work")
        let overlayPath = work.path + "-3p"
        try fm.createDirectory(atPath: overlayPath, withIntermediateDirectories: true)
        let overlayByLink = try linkedProfilesDir(env).appendingPathComponent("work-3p")

        let workProfile = try env.store.add(
            AddProfileRequest(name: env.name("work"), profilePath: work.path)
        ).profile
        _ = try env.store.add(
            AddProfileRequest(name: env.name("sibling"), profilePath: overlayByLink.path)
        ).profile
        let login = URL(fileURLWithPath: overlayPath).appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)

        let result = try env.store.remove(workProfile, purgeProfile: true)

        // The sibling's data is its own, not this profile's overlay — spared, under either
        // spelling.
        #expect(fm.fileExists(atPath: login.path))
        #expect(result.profileData == .purged)
    }

    /// An unlistable launcher folder makes the scan report no launchers, which is what an empty
    /// folder reports too. Reading that as "nobody else claims this data" is how a sibling's
    /// login gets deleted over a folder that was merely renamed or unmounted.
    @Test
    func purgeDeclinesWhenTheLauncherFolderCannotBeRead() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let login = URL(fileURLWithPath: profile.profilePath).appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)
        // Listable no more, but still traversable — so the launcher itself is still reachable
        // by path and the removal proceeds to the purge.
        try fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: env.installDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.installDir.path) }

        let result = try env.store.remove(profile, purgeProfile: true)

        #expect(result.profileData == .keptOwnersUnknown)
        #expect(fm.fileExists(atPath: login.path))
        let notice = try #require(result.profileData.notice(forRemovalOf: profile.displayName))
        #expect(notice.message.contains("could not be read"))
    }
}

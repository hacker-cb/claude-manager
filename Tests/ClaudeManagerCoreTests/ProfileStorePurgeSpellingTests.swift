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

    /// `removeItem` on a symbolic link unlinks the link and walks nothing, so a profile whose
    /// data path is a link endangers no one — however deeply other profiles' directories sit
    /// under its target. Canonicalising that into containment would refuse the removal *and*
    /// tell the user to delete the profile whose data is genuinely at risk if they comply.
    @Test
    func aProfileWhoseDataPathIsALinkCanStillBeRemoved() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("alias"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inner"))
        }
        let real = env.profilesDir.appendingPathComponent("real")
        let inner = real.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let alias = env.profilesDir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let login = inner.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)

        let aliasProfile = try env.store.add(
            AddProfileRequest(name: env.name("alias"), profilePath: alias.path)
        ).profile
        _ = try env.store.add(
            AddProfileRequest(name: env.name("inner"), profilePath: inner.path)
        )

        let result = try env.store.remove(aliasProfile, purgeProfile: true)

        #expect(result.profileData == .purged)
        // Only the link went; the directory it pointed at, and the profile inside it, remain.
        #expect(!fm.fileExists(atPath: alias.path))
        #expect(fm.fileExists(atPath: login.path))
    }

    /// Unlinking a link strands whatever was spelled *through* it. The sibling's bytes survive
    /// under the target, but its recorded path leads nowhere afterwards — so it is still what
    /// this removal affects, and the purge declines rather than proceeding.
    ///
    /// A **decline**, not the up-front refusal the nested case gets: nothing is destroyed here,
    /// and that refusal's message ("deleting it would delete their login and chat history too,
    /// remove that launcher first") would be false — and following its advice is what would
    /// actually destroy the sibling's data.
    @Test
    func removingALinkDeclinesWhenASiblingSpelledItsPathThroughIt() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("alias"))
            Fixture.purgeTrash(displayNamePrefix: env.display("under"))
        }
        let real = env.profilesDir.appendingPathComponent("real")
        try fm.createDirectory(at: real.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let alias = env.profilesDir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)

        let aliasProfile = try env.store.add(
            AddProfileRequest(name: env.name("alias"), profilePath: alias.path)
        ).profile
        // Spelled through the link, so the unlink takes its path away.
        let under = try env.store.add(
            AddProfileRequest(
                name: env.name("under"), profilePath: alias.appendingPathComponent("inner").path
            )
        ).profile

        let result = try env.store.remove(aliasProfile, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [under.displayName]))
        #expect(fm.fileExists(atPath: alias.path))
    }

    /// A sibling can sit under the purged directory only by the path it *recorded* — through a
    /// symlink inside that directory, the shape a user creates by moving one profile's data to
    /// an external disk and leaving a link behind. Canonicalising moves it out of containment,
    /// and the recursive delete then takes the link with the directory: the bytes survive on
    /// the other disk, the sibling can no longer find them.
    @Test
    func purgeSeesASiblingReachedThroughALinkInsideTheDirectory() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("moved"))
        }
        let outer = env.profilesDir.appendingPathComponent("outer")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        // "Moved to another disk, link left behind."
        let elsewhere = env.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let insideLink = outer.appendingPathComponent("moved")
        try fm.createSymbolicLink(at: insideLink, withDestinationURL: elsewhere)

        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        let moved = try env.store.add(
            AddProfileRequest(name: env.name("moved"), profilePath: insideLink.path)
        ).profile

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(outerProfile, purgeProfile: true)
        }

        // Refused before anything happens — afterwards this launcher is in the Trash and
        // nothing could finish the job — and the message says what would actually go: the
        // sibling's shortcut, not its data.
        #expect(fm.fileExists(atPath: outerProfile.appPath))
        #expect(fm.fileExists(atPath: outer.path))
        let message = try #require(thrown.errorDescription)
        #expect(message.contains(moved.displayName))
        #expect(message.contains("pointing at nothing"))
    }

    /// The same link, recorded by two profiles under different spellings of its parent. The
    /// unlink strands the sibling, so it has to be recognised — and recognised as the *link*,
    /// which is what tells it apart from a profile living under the link's target.
    @Test
    func purgeSeesASiblingRecordingTheSameLinkUnderAnotherSpelling() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("alias"))
            Fixture.purgeTrash(displayNamePrefix: env.display("twin"))
        }
        let real = env.profilesDir.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = env.profilesDir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasByLink = try linkedProfilesDir(env).appendingPathComponent("alias")

        let aliasProfile = try env.store.add(
            AddProfileRequest(name: env.name("alias"), profilePath: alias.path)
        ).profile
        let twin = try env.store.add(
            AddProfileRequest(name: env.name("twin"), profilePath: aliasByLink.path)
        ).profile

        let result = try env.store.remove(aliasProfile, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [twin.displayName]))
        #expect(fm.fileExists(atPath: alias.path))
    }

    /// The overlay sweep deletes its path recursively too, so a launcher whose data sits
    /// *inside* the `-3p` path is as exposed as one whose data is that path.
    @Test
    func purgeSparesALauncherLivingInsideThe3pPath() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("inside"))
        }
        let work = env.profilesDir.appendingPathComponent("work")
        let inside = URL(fileURLWithPath: work.path + "-3p").appendingPathComponent("inner")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)

        let workProfile = try env.store.add(
            AddProfileRequest(name: env.name("work"), profilePath: work.path)
        ).profile
        _ = try env.store.add(
            AddProfileRequest(name: env.name("inside"), profilePath: inside.path)
        )
        let login = inside.appendingPathComponent("login.json")
        try Data("token".utf8).write(to: login)

        _ = try env.store.remove(workProfile, purgeProfile: true)

        #expect(fm.fileExists(atPath: login.path))
    }

    /// A sibling that spelled its path through the purged link, reaching that link by another
    /// spelling of its parent. Unlinking strands it exactly as the same-spelling case does, so
    /// the two must behave alike — and comparing whole paths cannot see it, since resolving
    /// `…/ProfilesLink/alias/inner` resolves the link away before the comparison happens.
    @Test
    func removingALinkSeesASiblingThatReachedItByAnotherSpelling() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("alias"))
            Fixture.purgeTrash(displayNamePrefix: env.display("under"))
        }
        let real = env.profilesDir.appendingPathComponent("real")
        try fm.createDirectory(at: real.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let alias = env.profilesDir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)

        let aliasProfile = try env.store.add(
            AddProfileRequest(name: env.name("alias"), profilePath: alias.path)
        ).profile
        let under = try env.store.add(
            AddProfileRequest(
                name: env.name("under"),
                profilePath: linkedProfilesDir(env)
                    .appendingPathComponent("alias/inner").path
            )
        ).profile

        let result = try env.store.remove(aliasProfile, purgeProfile: true)

        // Declined, naming the sibling — and the link is still there, so the sibling's path
        // still resolves. Nothing was lost, which is why this is a decline rather than the
        // up-front refusal the nested case gets.
        #expect(result.profileData == .keptSharedWith(launchers: [under.displayName]))
        #expect(fm.fileExists(atPath: alias.path))
    }

    /// The link being unlinked is an entry in someone else's directory: a launcher that owns
    /// the link's physical parent owns the link too, so removing it changes that profile's
    /// data. Reached here through an aliased parent, which is what puts the two paths beyond a
    /// literal comparison.
    @Test
    func removingALinkSeesTheLauncherOwningItsParent() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("alias"))
            Fixture.purgeTrash(displayNamePrefix: env.display("parent"))
        }
        let real = env.profilesDir.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: env.profilesDir.appendingPathComponent("alias"), withDestinationURL: real
        )
        // The purged profile reaches its link through an alias of the parent directory.
        let aliasByLink = try linkedProfilesDir(env).appendingPathComponent("alias")

        let aliasProfile = try env.store.add(
            AddProfileRequest(name: env.name("alias"), profilePath: aliasByLink.path)
        ).profile
        // And this one owns the directory the link physically lives in.
        let parent = try env.store.add(
            AddProfileRequest(name: env.name("parent"), profilePath: env.profilesDir.path)
        ).profile

        let result = try env.store.remove(aliasProfile, purgeProfile: true)

        #expect(result.profileData == .keptSharedWith(launchers: [parent.displayName]))
        #expect(fm.fileExists(atPath: env.profilesDir.appendingPathComponent("alias").path))
    }

    /// The literal question has to fold case the way the volume does. Here the sibling is
    /// reached through a link *inside* the purged directory — so the canonical comparison
    /// resolves it out of containment — and records the path in another case, which a plain
    /// string comparison of components would miss.
    @Test
    func purgeSeesASiblingWhoseLinkedPathIsSpelledInAnotherCase() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("cased"))
        }
        let outer = env.profilesDir.appendingPathComponent("Outer")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        let elsewhere = env.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: outer.appendingPathComponent("Alias"), withDestinationURL: elsewhere
        )
        let volumeIgnoresCase = fm.fileExists(
            atPath: env.profilesDir.appendingPathComponent("outer").path
        )

        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        // Same link, spelled in another case throughout.
        let cased = try env.store.add(
            AddProfileRequest(
                name: env.name("cased"),
                profilePath: env.profilesDir.appendingPathComponent("outer/alias/inner").path
            )
        ).profile

        let outcome = Result { try env.store.remove(outerProfile, purgeProfile: true) }

        if volumeIgnoresCase {
            guard case let .failure(error) = outcome else {
                Issue.record("expected a refusal naming \(cased.displayName)")
                return
            }
            #expect(
                try #require((error as? ClaudeManagerError)?.errorDescription)
                    .contains(cased.displayName)
            )
            #expect(fm.fileExists(atPath: outer.path))
        } else {
            // On a case-sensitive volume the two paths really are different directories.
            #expect(try outcome.get().profileData == .purged)
        }
    }
}

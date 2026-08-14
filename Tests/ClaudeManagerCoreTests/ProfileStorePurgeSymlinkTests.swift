import Foundation
import Testing
@testable import ClaudeManagerCore

/// `removeItem` on a symbolic link unlinks the link and walks no further, so a purge whose
/// data path is one — or whose directory holds one another profile reached its data through
/// — destroys nothing and *strands*: the bytes survive, the recorded path stops resolving.
/// Reporting that as a deletion is the dangerous half, because its remedy ("remove that
/// launcher together with its data") is what would actually destroy the login.
///
/// Separate file/suite so `ProfileStorePurgeSpellingTests` stays within the length cap.
struct ProfileStorePurgeSymlinkTests {
    let fm = FileManager.default

    /// A symlinked parent, which is how a second spelling reaches a marker.
    private func linkedProfilesDir(_ env: StoreEnv) throws -> URL {
        let link = env.root.appendingPathComponent("profiles-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: env.profilesDir)
        return link
    }

    /// A sibling that shares no ground with this profile — its data lives elsewhere and it
    /// only reached it through a shortcut in here — loses a path, not bytes. Saying so with
    /// `keptSharedWith` would claim its login would be deleted and tell the user to remove it
    /// *with its data*, which is the one action that destroys what was never at risk.
    @Test
    func aStrandedSiblingIsToldApartFromOneWhoseDataWouldGo() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("moved"))
        }
        let outer = env.profilesDir.appendingPathComponent("outer")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        let elsewhere = env.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: outer.appendingPathComponent("moved"), withDestinationURL: elsewhere
        )
        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        // Recorded through the shortcut, so its own data is outside this directory entirely.
        let moved = try env.store.add(
            AddProfileRequest(
                name: env.name("moved"),
                profilePath: outer.appendingPathComponent("moved").path
            )
        ).profile

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(outerProfile, purgeProfile: true)
        }

        // Caught before anything is touched, and told apart there too: the message names a lost
        // shortcut rather than a deleted login.
        let refusal = try #require(thrown.errorDescription)
        #expect(refusal.contains(moved.displayName))
        #expect(refusal.contains("pointing at nothing"))
        #expect(!refusal.contains("Delete Profile Data"))
        let result = try env.store.remove(outerProfile, purgeProfile: false)
        #expect(result.profileData == .notRequested)
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

        // Its *data* is not at risk — the unlink would take the shortcut sitting in its
        // directory — so it is named as stranded, not as a profile whose login would go.
        #expect(result.profileData == .keptWouldStrand(launchers: [parent.displayName]))
        #expect(fm.fileExists(atPath: env.profilesDir.appendingPathComponent("alias").path))
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

        #expect(result.profileData == .keptWouldStrand(launchers: [under.displayName]))
        #expect(fm.fileExists(atPath: alias.path))
    }

    /// The sibling reached the shortcut through a differently spelled ancestor. The literal
    /// comparison misses it (the spelling differs) and the canonical one resolves the shortcut
    /// out of this directory entirely — so without asking a third way, the deletion takes the
    /// shortcut and says nothing at all.
    @Test
    func aSiblingReachingTheShortcutByAnAliasedAncestorIsSeen() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("outer"))
            Fixture.purgeTrash(displayNamePrefix: env.display("moved"))
        }
        let outer = env.profilesDir.appendingPathComponent("outer")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        let elsewhere = env.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: outer.appendingPathComponent("moved"), withDestinationURL: elsewhere
        )

        let outerProfile = try env.store.add(
            AddProfileRequest(name: env.name("outer"), profilePath: outer.path)
        ).profile
        let moved = try env.store.add(
            AddProfileRequest(
                name: env.name("moved"),
                profilePath: linkedProfilesDir(env)
                    .appendingPathComponent("outer/moved").path
            )
        ).profile

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.remove(outerProfile, purgeProfile: true)
        }

        #expect(fm.fileExists(atPath: outer.appendingPathComponent("moved").path))
        #expect(try #require(thrown.errorDescription).contains(moved.displayName))
    }
}

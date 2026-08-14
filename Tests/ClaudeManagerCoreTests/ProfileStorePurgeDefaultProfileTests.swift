import Foundation
import Testing
@testable import ClaudeManagerCore

/// The default profile's user-data directory is Claude's own login and chat history, and it
/// owns no launcher — so it appears in no scan and the sharing check cannot speak for it.
/// What protects it is its own guard, and that guard has to answer the question the purge
/// actually asks: a recursive delete reaches everything under the path, not only the path.
///
/// Separate file/suite so `ProfileStorePurgeSpellingTests` stays within the length cap.
struct ProfileStorePurgeDefaultProfileTests {
    let fm = FileManager.default

    /// The default profile's directory is Claude's own, and the purge is recursive — so a
    /// profile whose data path is an *ancestor* of it reaches it just as surely as one that is
    /// it. The "Profile data" field is free text, so `~/Library/Application Support` is a
    /// profile someone can create; deleting that takes the user's real Claude login, their
    /// whole chat history, and every other app's data in there.
    @Test
    func purgeIsDeclinedWhenTheDataDirectoryContainsTheDefaultProfiles() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("wide"))
        }
        // `makeStoreEnv` puts the default profile's stand-in at `<root>/default-profile/Claude`.
        let ancestor = URL(fileURLWithPath: env.defaultProfileUserDataPath)
            .deletingLastPathComponent()
        try fm.createDirectory(
            at: URL(fileURLWithPath: env.defaultProfileUserDataPath),
            withIntermediateDirectories: true
        )
        let login = URL(fileURLWithPath: env.defaultProfileUserDataPath)
            .appendingPathComponent("login.json")
        try Data("claude's own".utf8).write(to: login)

        let wide = try env.store.add(
            AddProfileRequest(name: env.name("wide"), profilePath: ancestor.path)
        ).profile

        let result = try env.store.remove(wide, purgeProfile: true)

        #expect(result.profileData == .keptForDefaultProfile)
        #expect(fm.fileExists(atPath: login.path))
    }
}

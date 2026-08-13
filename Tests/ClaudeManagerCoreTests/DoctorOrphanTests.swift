import Foundation
import Testing
@testable import ClaudeManagerCore

/// Doctor's orphan sweep — the check whose false positives name a directory holding the
/// user's Anthropic login and chat history as safe to delete. Separate file/suite so
/// `DoctorTests` stays within the length cap; shares its top-level fixtures.
struct DoctorOrphanTests {
    let fm = FileManager.default

    /// An unreadable launcher folder — renamed, unmounted, permissions changed — makes `scan`
    /// report no launchers, so every profile directory looks unclaimed. Reported as orphans,
    /// that is a list of the user's logins and chat histories under a title that means "safe to
    /// delete".
    @Test
    func doesNotCallEveryProfileAnOrphanWhenTheLauncherFolderIsUnreadable() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try fm.createDirectory(
            at: scene.profilesDir.appendingPathComponent("work"), withIntermediateDirectories: true
        )
        try buildDoctorLauncher(in: scene, name: "work", profileDir: nil)
        // The folder goes away after the launcher was built into it.
        try fm.removeItem(at: scene.installDir)

        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))

        #expect(!diags.contains { $0.title == "Orphan profile (no launcher)" })
        #expect(diags.contains { $0.title.contains("Could not read every launcher") })
    }

    /// The default profile owns no launcher, so no marker claims its directory — and the
    /// profiles folder is user-settable, so it can be pointed at the folder holding it
    /// (`~/Library/Application Support`). Reported as an orphan, that names the user's primary
    /// Anthropic login and chat history as safe to delete.
    @Test
    func doesNotCallTheDefaultProfilesDataAnOrphan() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        // The profiles folder *is* the folder the default profile's data sits in.
        let profilesDir = URL(fileURLWithPath: scene.defaultProfilePath).deletingLastPathComponent()
        try fm.createDirectory(
            at: URL(fileURLWithPath: scene.defaultProfilePath), withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: profilesDir.appendingPathComponent("ghost"), withIntermediateDirectories: true
        )

        let diags = runDoctor(
            scene, runner: RecordingCommandRunner(handler: idleStub), profilesDirectory: profilesDir
        )

        let orphans = diags.filter { $0.title == "Orphan profile (no launcher)" }.compactMap(\.detail)
        #expect(orphans.count == 1)
        #expect(orphans.first?.hasSuffix("/ghost") == true)
    }
}

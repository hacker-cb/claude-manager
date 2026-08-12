import Foundation
import Testing
@testable import ClaudeManagerCore

/// A profile must be the launcher installed at its own path — the invariant `ProfileEdits`,
/// the `let` identity fields and `profileMatchingItsLauncher` exist to hold together.
/// Separate file/suite so no single test file grows past the length cap; shares
/// `makeStoreEnv` with the other ProfileStore suites.
struct ProfileIdentityTests {
    let fm = FileManager.default

    @Test
    func addWithForceRefusesToRepointAnExistingLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let token = URL(fileURLWithPath: original.profilePath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: token)
        let elsewhere = env.profilesDir.appendingPathComponent("elsewhere").path

        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(
                name: env.name("work"), profilePath: elsewhere, force: true
            ))
        }
        // Nothing moved: the launcher still opens the directory that holds the login.
        let marker = try #require(LauncherBundle().readMarker(at: original.appURL))
        #expect(marker.marker.profile == original.profilePath)
        #expect(fm.fileExists(atPath: token.path))
        #expect(!fm.fileExists(atPath: elsewhere))
    }

    /// Two launchers may share one profile directory, so the directory alone does not identify
    /// which launcher a forced create is rebuilding. Without the name check, a force carrying
    /// the sibling's display name replaces that sibling and writes this profile's name into its
    /// marker — a rename performed through a create.
    @Test
    func addWithForceRefusesASiblingSharingTheProfileDirectory() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("one"))
            Fixture.purgeTrash(displayNamePrefix: env.display("two"))
        }
        let shared = env.profilesDir.appendingPathComponent("shared").path
        _ = try env.store.add(AddProfileRequest(name: env.name("one"), profilePath: shared))
        let two = try env.store
            .add(AddProfileRequest(name: env.name("two"), profilePath: shared)).profile

        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(
                name: env.name("one"),
                displayName: two.displayName, // aims at the sibling's bundle
                profilePath: shared,
                force: true
            ))
        }
        // The sibling still carries its own name.
        let marker = try #require(LauncherBundle().readMarker(at: two.appURL))
        #expect(marker.marker.name == two.name)
    }

    /// The same path spelled differently is the same directory, so a force rebuild through it
    /// is an ordinary rebuild — the refusal above must not fire on it, and the marker must
    /// keep the spelling it had. `runningPID` greps for the literal path, so adopting the
    /// requested spelling instead would miss a live instance launched under the recorded one
    /// and leave `list` and `remove` blind to it afterwards.
    @Test
    func addWithForceAcceptsTheSameDirectorySpeltDifferently() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let roundabout = original.profilePath + "/./"

        let rebuilt = try env.store.add(AddProfileRequest(
            name: env.name("work"), profilePath: roundabout, force: true
        ))
        #expect(rebuilt.profile.appPath == original.appPath)
        #expect(rebuilt.profile.profilePath == original.profilePath)
        let marker = try #require(LauncherBundle().readMarker(at: original.appURL))
        #expect(marker.marker.profile == original.profilePath)
    }

    /// `force` must never overwrite a bundle that is not one of ours. `build` finishes with
    /// `replaceItemAt`, which deletes what it replaces, and the default install directory is
    /// the real Claude.app's own — so a display name of "Claude" would destroy the user's
    /// Claude installation and every launcher's baked binary path along with it.
    @Test
    func addWithForceRefusesABundleThatIsNotOurs() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A bundle with no marker, sitting where the forced create would land.
        let stranger = env.installDir.appendingPathComponent("\(env.display("work")).app")
        try fm.createDirectory(
            at: stranger.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let witness = stranger.appendingPathComponent("Contents/keep")
        try Data("not ours".utf8).write(to: witness)

        #expect(throws: ClaudeManagerError.self) {
            try env.store.add(AddProfileRequest(name: env.name("work"), force: true))
        }
        // Untouched — the point of the refusal.
        #expect(fm.fileExists(atPath: witness.path))
    }

    /// With no launcher at the path, `update` *creates* one — so it owes the same checks `add`
    /// makes on a fresh profile. The name check is skipped only when an installed marker has
    /// vouched for the name; `draft` derives the data directory from it, so an unvouched
    /// `../bad` would put that directory outside the profiles folder.
    @Test
    func updateValidatesTheNameWhenNoLauncherVouchesForIt() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let forged = env.store.draft(name: "../bad", displayName: env.display("ok"))

        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(forged, applying: ProfileEdits(forged))
        }
        #expect(!fm.fileExists(atPath: forged.appPath))
    }

    /// The sharpest edge: a bundle that is not ours must never be built over, trashed, or
    /// removed. `build` ends in `replaceItemAt`, which deletes what it replaces, and the
    /// default install directory is the real Claude.app's own — so a profile drafted with the
    /// display name "Claude" would otherwise destroy the user's Claude installation.
    @Test
    func writesRefuseABundleThatIsNotOurs() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let stranger = env.installDir.appendingPathComponent("Stranger.app")
        try fm.createDirectory(
            at: stranger.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let witness = stranger.appendingPathComponent("Contents/keep")
        try Data("not ours".utf8).write(to: witness)

        let aimed = env.store.draft(name: env.name("x"), displayName: "Stranger")
        #expect(aimed.appPath == stranger.path)

        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(aimed, applying: ProfileEdits(aimed))
        }
        #expect(throws: ClaudeManagerError.self) { try env.store.rebuild(aimed) }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.remove(aimed, purgeProfile: false)
        }
        // Still there, untouched — none of the three wrote to it or moved it.
        #expect(fm.fileExists(atPath: witness.path))
        #expect(try Data(contentsOf: witness) == Data("not ours".utf8))
    }

    /// `update` and `rebuild` build straight from the profile they are handed, and `draft` is
    /// public — so a profile can be shaped to sit on another launcher's bundle even though
    /// `Profile`'s initialiser is internal. Both check against the installed marker.
    @Test
    func updateAndRebuildRefuseAProfilePointingAtAnotherLauncher() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let victim = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let token = URL(fileURLWithPath: victim.profilePath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: token)

        // Reachable through the public factory: same display name (so the derived bundle path
        // is the victim's), a different data directory.
        let forged = env.store.draft(
            name: env.name("work"),
            displayName: victim.displayName,
            profilePath: env.profilesDir.appendingPathComponent("elsewhere").path
        )
        #expect(forged.appPath == victim.appPath)

        #expect(throws: ClaudeManagerError.self) {
            try env.store.update(forged, applying: ProfileEdits(forged))
        }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.rebuild(forged)
        }
        // The victim still opens its own data, and that data is still there.
        let marker = try #require(LauncherBundle().readMarker(at: victim.appURL))
        #expect(marker.marker.profile == victim.profilePath)
        #expect(fm.fileExists(atPath: token.path))
    }

    /// A launcher whose hand-edited marker holds an invalid name must stay editable: the name
    /// is not something an edit can carry or a path is derived from, so rejecting the edit over
    /// it would lock the profile out of the app with no field able to correct it.
    @Test
    func aProfileWithAnInvalidMarkerNameCanStillBeEdited() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Hand-edit the marker the way a user (or an older build) could. `readMarker`
        // validates nothing, so this stays an ordinary sidebar row.
        let plist = profile.appURL.appendingPathComponent("Contents/Info.plist")
        var info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        var marker = try #require(info[CoreConstants.markerKey] as? [String: Any])
        marker["name"] = "not a valid name"
        info[CoreConstants.markerKey] = marker
        try (info as NSDictionary).write(to: plist)
        // Read back through the same path `add` reported, so the bundle path is spelled the
        // way the store derives it and this exercises the name, not path normalisation.
        let handEdited = try #require(LauncherBundle().readMarker(at: profile.appURL)).profile
        #expect(handEdited.name == "not a valid name")

        var edits = ProfileEdits(handEdited)
        edits.color = .named("red")
        let result = try env.store.update(handEdited, applying: edits)

        #expect(result.profile.color == .named("red"))
        // The name is carried through untouched — the edit neither fixes nor rejects it.
        #expect(result.profile.name == "not a valid name")
    }
}

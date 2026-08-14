import Foundation
import Testing
@testable import ClaudeManagerCore

/// Whether the volume holding `url` folds case — macOS's own default (APFS, case-insensitive),
/// and the condition under which `Work.app` and `WORK.app` are one bundle rather than two.
///
/// Asked of the volume rather than assumed, because both answers are ordinary: a developer
/// working on a case-sensitive APFS volume gets genuinely different behaviour, and a test that
/// asserted the folding one there would fail for a correct build. The tests below split on it —
/// most hold either way, and the few that describe the collision itself are gated on this.
///
/// Unreadable answers count as case-*sensitive*: that skips the gated tests rather than running
/// them against a volume whose behaviour is unknown.
func volumeFoldsCase(at url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
        .volumeSupportsCaseSensitiveNames == false
}

/// Renaming a launcher to another capitalisation of its own name.
///
/// This is the one rename whose destination is the profile's *own* bundle. On a case-insensitive
/// volume the two spellings open one file, so every check phrased as "is something already
/// there?" answers yes and names the launcher being renamed — and every step phrased as "retire
/// the old bundle" would retire the new one. Both were wrong: the edit was refused outright, and
/// removing the refusal alone would have left the profile with no launcher at all.
///
/// Separate file/suite so no single test file grows past the length cap; shares `makeStoreEnv`
/// with the other ProfileStore suites.
struct ProfileStoreCaseRenameTests {
    let fm = FileManager.default

    /// The `.app` names actually on disk — read by listing, so the assertion is about the names
    /// the volume stores rather than about paths that merely open.
    private func installedNames(in env: StoreEnv) throws -> [String] {
        try fm.contentsOfDirectory(atPath: env.installDir.path)
            .filter { $0.hasSuffix(".app") }
            .sorted()
    }

    /// The whole point, and it holds on either kind of volume: after the edit the launcher is on
    /// disk under the requested spelling, there is exactly one of it, and the login and chat
    /// history are where they were.
    ///
    /// The name is asserted from a directory listing, not from `fileExists`: on a
    /// case-insensitive volume the old name answers that check just as well, so a launcher left
    /// under its previous spelling would pass it while the sidebar showed the new one — one
    /// bundle under two identities, since `Profile.id` *is* `appPath`.
    @Test
    func aRenameThatOnlyChangesCaseLandsUnderTheNewSpelling() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("work").uppercased())
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // Stands in for the Anthropic token and the chat history.
        let token = URL(fileURLWithPath: original.profilePath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: token)

        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()
        let updated = try env.store.update(original, applying: edits).profile

        #expect(updated.displayName == original.displayName.uppercased())
        #expect(try installedNames(in: env) == ["\(edits.displayName).app"])
        #expect(env.store.list().map(\.profile.appPath) == [updated.appPath])
        #expect(updated.profilePath == original.profilePath)
        #expect(try Data(contentsOf: token) == Data("secret".utf8))
    }

    /// The marker follows the bundle. A rename that changed the file's name but left the
    /// launcher describing itself by the old one would put `scan` and the editor at odds about
    /// what this profile is called, while both read as authoritative.
    @Test
    func aCaseOnlyRenameCarriesTheNameIntoTheBundle() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("work").uppercased())
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()

        let updated = try env.store.update(original, applying: edits).profile

        let discovered = try #require(LauncherBundle().readMarker(at: updated.appURL))
        #expect(discovered.displayName == edits.displayName)
        // The profile's identity is untouched by a rename — only its presentation moved.
        #expect(discovered.marker.name == original.name)
        #expect(discovered.marker.profile == original.profilePath)
    }

    /// The step that would have destroyed the edit: on a case-insensitive volume the "old"
    /// bundle a rename retires is the very file `build` has just written under its new name, so
    /// trashing it leaves the profile with no launcher — and its user-data directory with
    /// nothing in the app pointing at it.
    ///
    /// Asserted by making every `trashItem` throw: the edit succeeding at all proves nothing was
    /// sent to the Trash, which no amount of looking at `~/.Trash` afterwards could show as
    /// firmly (a parallel test's launcher can land there under any name).
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aCaseOnlyRenameNeverTrashesTheLauncherItJustBuilt() throws {
        // No `purgeTrash` cleanup: this store refuses every `trashItem`, so nothing of its
        // making ever reaches the Trash.
        let env = try makeStoreEnv(fileManager: TrashRefusingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()

        let updated = try env.store.update(original, applying: edits).profile

        #expect(try installedNames(in: env) == ["\(edits.displayName).app"])
        #expect(env.store.list().map(\.profile.appPath) == [updated.appPath])
    }

    /// The guard this change had to keep. Identity, not spelling, is what makes a destination
    /// free: another profile's launcher is another file however its name is capitalised, and
    /// `build` ends in `replaceItemAt`, which deletes what it replaces.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aRenameOntoAnotherLaunchersBundleIsRefusedWhateverTheCase() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("aa"))
            Fixture.purgeTrash(displayNamePrefix: env.display("bb"))
        }
        let first = try env.store.add(AddProfileRequest(name: env.name("aa"))).profile
        let second = try env.store.add(AddProfileRequest(name: env.name("bb"))).profile
        let secondsToken = URL(fileURLWithPath: second.profilePath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: secondsToken)

        var edits = ProfileEdits(first)
        edits.displayName = second.displayName.uppercased()
        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.update(first, applying: edits)
        }

        #expect(thrown.errorDescription?.isEmpty == false)
        // Both launchers stand, under the names they had, and nobody's data was touched.
        #expect(try installedNames(in: env) == [
            "\(first.displayName).app", "\(second.displayName).app"
        ].sorted())
        #expect(try Data(contentsOf: secondsToken) == Data("secret".utf8))
    }

    /// The same promise on the create path. `add(force:)` rebuilds the launcher already at the
    /// path, so a forced re-create under a new capitalisation runs into `replaceItemAt` keeping
    /// the installed file's name exactly as a rename does.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aForcedAddRebuildsUnderTheRequestedSpelling() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
            Fixture.purgeTrash(displayNamePrefix: env.display("work").uppercased())
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let shouted = original.displayName.uppercased()

        let rebuilt = try env.store.add(AddProfileRequest(
            name: env.name("work"), displayName: shouted, force: true
        )).profile

        #expect(try installedNames(in: env) == ["\(shouted).app"])
        #expect(rebuilt.appPath == env.installDir.appendingPathComponent("\(shouted).app").path)
    }

    /// `build`'s own promise, held to directly: the bundle ends up at the path it was handed.
    /// Everything above depends on it, and `replaceItemAt` does not provide it — it writes into
    /// the file already at the path and keeps *that* file's name.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func buildInstallsUnderTheSpellingItWasAskedFor() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let shouted = Profile(
            name: profile.name,
            displayName: profile.displayName.uppercased(),
            label: profile.label,
            color: profile.color,
            profilePath: profile.profilePath,
            bundleID: profile.bundleID,
            appPath: env.installDir
                .appendingPathComponent("\(profile.displayName.uppercased()).app").path
        )

        try LauncherBundle().build(
            profile: shouted,
            realBinaryPath: env.real.binaryURL.path,
            icnsData: Fixture.baseICNSData()
        )

        #expect(try installedNames(in: env) == ["\(shouted.displayName).app"])
    }
}

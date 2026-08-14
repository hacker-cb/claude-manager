import Foundation
import Testing
@testable import ClaudeManagerCore

/// Whether the volume holding `url` opens these two spellings of one name as a **single file**.
///
/// Answered by writing one and looking for the other, because the volume is the only authority
/// on which spellings it folds and the rule is not the obvious one: APFS folds `Σ`, `σ` and `ς`
/// together, which no amount of `lowercased()` reproduces. `volumeSupportsCaseSensitiveNames`
/// would answer the ASCII question alone, and this file needs both.
///
/// Both answers are ordinary — a developer working on a case-sensitive volume gets genuinely
/// different behaviour, and a test asserting the folding one there would fail a correct build —
/// so the tests describing a collision are gated on this, while the ones that hold either way
/// are not. A probe that cannot be written counts as *not* folding, which skips those tests
/// rather than running them against a volume whose behaviour is unknown.
func volumeFolds(_ spelling: String, and other: String, at url: URL) -> Bool {
    let fm = FileManager.default
    let probe = url.appendingPathComponent("cm-fold-probe-\(UUID().uuidString)")
    guard (try? fm.createDirectory(at: probe, withIntermediateDirectories: true)) != nil
    else { return false }
    defer { try? fm.removeItem(at: probe) }
    guard (try? Data().write(to: probe.appendingPathComponent(spelling))) != nil else { return false }
    return fm.fileExists(atPath: probe.appendingPathComponent(other).path)
}

/// The ASCII case of `volumeFolds` — macOS's own default (APFS, case-insensitive), and the
/// condition under which `Work.app` and `WORK.app` are one bundle rather than two.
func volumeFoldsCase(at url: URL) -> Bool {
    volumeFolds("Work", and: "WORK", at: url)
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
            // Only the original spelling can ever reach the Trash — on a case-sensitive
            // volume, where the rename is an ordinary one. The new spelling names precisely
            // the launcher this fix keeps *out* of it.
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
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
            // Only the original spelling can ever reach the Trash — on a case-sensitive
            // volume, where the rename is an ordinary one. The new spelling names precisely
            // the launcher this fix keeps *out* of it.
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
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

        // The collision guard is what refused, named by its own case — not merely "something
        // threw", which a validation failure or a marker mismatch would satisfy too. And it
        // names the launcher **as the volume stores it**: the message tells the user to remove
        // that file in Finder, and the spelling they typed is not one that exists there.
        #expect(thrown == .launcherAlreadyExists(path: second.appPath))
        #expect(thrown.errorDescription?.contains(second.displayName) == true)
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
            // Only the original spelling can ever reach the Trash — on a case-sensitive
            // volume, where the rename is an ordinary one. The new spelling names precisely
            // the launcher this fix keeps *out* of it.
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let shouted = original.displayName.uppercased()

        let rebuilt = try env.store.add(AddProfileRequest(
            name: env.name("work"), displayName: shouted, force: true
        )).profile

        #expect(try installedNames(in: env) == ["\(shouted).app"])
        #expect(rebuilt.appPath == env.installDir.appendingPathComponent("\(shouted).app").path)
    }

    /// The same rename where the volume's folding is not the one a case rule would guess. APFS
    /// opens `Σ`, `σ` and `ς` as one file; `"Σ".lowercased()` is `σ` and `"ς".lowercased()` is
    /// `ς`, so anything phrased as "these differ only in case" declines here — and declines
    /// precisely where the collision is real, leaving `update` returning a path that the bundle
    /// on disk does not have. `Profile.id` *is* that path, and `liveRewrite` matches on it
    /// exactly, so the launcher goes on running with the restart nudge silently gone.
    ///
    /// Display names are free text (`isValidDisplayName` bars separators and dot-names, nothing
    /// else), so this is reachable from the editor, not a contrived string.
    @Test(.enabled(if: volumeFolds("Σ", and: "ς", at: FileManager.default.temporaryDirectory)))
    func aRenameBetweenSpellingsTheVolumeFoldsLandsOnDisk() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: "Σ\(env.token)")
        }
        let original = try env.store.add(AddProfileRequest(
            name: env.name("work"), displayName: "Σ\(env.token)"
        )).profile
        var edits = ProfileEdits(original)
        edits.displayName = "ς\(env.token)"

        let updated = try env.store.update(original, applying: edits).profile

        #expect(try installedNames(in: env) == ["ς\(env.token).app"])
        #expect(env.store.list().map(\.profile.appPath) == [updated.appPath])
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

        // Stubbed signer and throwaway icns bytes: this asserts a file name, so a real
        // `codesign`/`iconutil` per write would only buy a subprocess and a failure mode
        // (`codesign` unavailable) that has nothing to do with what is under test. The
        // signature across this step is `LauncherSigningTests`' business, where the real tool
        // runs serialized.
        try LauncherBundle(runner: stubbedSigningRunner()).build(
            profile: shouted, realBinaryPath: env.real.binaryURL.path, icnsData: Data("i".utf8)
        )

        #expect(try installedNames(in: env) == ["\(shouted.displayName).app"])
    }

    /// The rename's other half, and the one that loses a launcher outright: retiring the old
    /// bundle. Identity has to be asked **again** after the build, because before it there was
    /// nothing to ask about — the launcher was not on disk, a state `profileMatchingItsLauncher`
    /// supports on purpose (deleted from Finder while the editor sheet was open). `build` then
    /// creates the bundle, the old path folds onto it, and the retire step trashes the launcher
    /// that was just built: success reported, sidebar empty, login left behind.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aCaseOnlyRenameOfAnAbsentLauncherKeepsTheOneItBuilds() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let token = URL(fileURLWithPath: original.profilePath).appendingPathComponent("token")
        try Data("secret".utf8).write(to: token)
        // Deleted from under the app, exactly as Finder or a cleanup script would.
        try fm.removeItem(at: original.appURL)

        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()
        let updated = try env.store.update(original, applying: edits).profile

        #expect(try installedNames(in: env) == ["\(edits.displayName).app"])
        #expect(env.store.list().map(\.profile.appPath) == [updated.appPath])
        #expect(try Data(contentsOf: token) == Data("secret".utf8))
    }

    /// A `Profile` captured before the edit — a row's context menu, a detail pane — must not undo
    /// it. `build` writes the bundle's name, marker and badge from the profile it is handed, and
    /// after a rename in place the pre-rename path still opens the same bundle, so nothing threw
    /// the way it used to: the launcher was renamed back, `CFBundleName` rewritten with it, and
    /// as much of the rest of the edit reverted as the stale value carried.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aRebuildFromAStaleProfileDoesNotUndoAnEditMadeInPlace() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let stale = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var edits = ProfileEdits(stale)
        edits.displayName = stale.displayName.uppercased()
        edits.color = .named("red")
        edits.label = "ZZ"
        let renamed = try env.store.update(stale, applying: edits).profile

        try env.store.rebuild(stale)

        #expect(try installedNames(in: env) == ["\(renamed.displayName).app"])
        #expect(env.store.list().map(\.profile.displayName) == [renamed.displayName])
        // The rename is the visible half; every other edited field rides on the same value.
        let discovered = try #require(LauncherBundle().readMarker(at: renamed.appURL))
        #expect(discovered.marker.color == "red")
        #expect(discovered.marker.label == "ZZ")
    }

    /// The undo has to know *what* it is undoing. A swap that fails having already installed the
    /// staged bundle leaves the new marker and settings at the path, and moving that back under
    /// the old name would manufacture the very split identity the undo exists to prevent — a
    /// launcher whose file says one thing and whose marker says another, produced by the repair.
    /// Identity is what tells the two bundles apart; both answer to the same path.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aSwapThatFailsAfterInstallingIsNotUndoneByRenaming() throws {
        let env = try makeStoreEnv(fileManager: ReplaceThenFailingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()
        edits.color = .named("red")

        #expect(throws: (any Error).self) { try env.store.update(original, applying: edits) }

        // The swap did land, so what is installed is the edited bundle — and it keeps the name
        // that belongs to it rather than being dragged back under the old one.
        #expect(try installedNames(in: env) == ["\(edits.displayName).app"])
        let installed = env.installDir.appendingPathComponent("\(edits.displayName).app")
        let discovered = try #require(LauncherBundle().readMarker(at: installed))
        #expect(discovered.displayName == edits.displayName)
        #expect(discovered.marker.color == "red")
    }

    /// The swap is the last thing that can fail after the bundle has been renamed, and the rename
    /// is the one part of a failed build that does not undo itself. Left in place, the launcher
    /// answers to the new name while its marker still holds the old one — the same split
    /// identity, reached from the other side.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aFailedSwapPutsTheSpellingBack() throws {
        let env = try makeStoreEnv(fileManager: ReplaceRefusingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()

        #expect(throws: (any Error).self) { try env.store.update(original, applying: edits) }

        #expect(try installedNames(in: env) == ["\(original.displayName).app"])
        let discovered = try #require(LauncherBundle().readMarker(at: original.appURL))
        #expect(discovered.displayName == original.displayName)
    }

    /// The rename runs **before** the atomic swap, so its failure is like every other failure in
    /// `build`: the previous launcher is left whole. Run after the swap it would throw with the
    /// rebuilt bundle already installed under the old name — an edit reported as failed, its
    /// marker already carrying the new display name, and the launcher's file disagreeing with
    /// `Profile.id`, which is the split identity this whole change exists to close.
    @Test(.enabled(if: volumeFoldsCase(at: FileManager.default.temporaryDirectory)))
    func aFailedSpellingRenameLeavesThePreviousLauncherIntact() throws {
        let env = try makeStoreEnv(fileManager: RenameRefusingFileManager())
        defer { try? fm.removeItem(at: env.root) }
        let original = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let colorBefore = try #require(LauncherBundle().readMarker(at: original.appURL)).marker.color
        var edits = ProfileEdits(original)
        edits.displayName = original.displayName.uppercased()
        edits.color = .named("red")

        #expect(throws: (any Error).self) { try env.store.update(original, applying: edits) }

        // Same launcher, same name, same badge: nothing of the edit landed.
        #expect(try installedNames(in: env) == ["\(original.displayName).app"])
        let discovered = try #require(LauncherBundle().readMarker(at: original.appURL))
        #expect(discovered.marker.color == colorBefore)
        #expect(env.store.list().map(\.profile.appPath) == [original.appPath])
    }
}

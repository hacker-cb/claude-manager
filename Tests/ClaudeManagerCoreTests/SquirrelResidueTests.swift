import Foundation
import Testing
@testable import ClaudeManagerCore

/// Clearing what Claude's own updater leaves behind once it is switched off.
struct SquirrelResidueTests {
    let fm = FileManager.default

    private struct Scene {
        let root: URL
        let statePath: String
    }

    private func makeScene() throws -> Scene {
        let root = fm.temporaryDirectory.appendingPathComponent("cm-squirrel-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("com.anthropic.claudefordesktop.ShipIt")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        return Scene(root: root, statePath: cache.appendingPathComponent("ShipItState.plist").path)
    }

    private func armJob(_ scene: Scene, bundleName: String = "update.MxqCNfY") throws -> URL {
        let cache = URL(fileURLWithPath: scene.statePath).deletingLastPathComponent()
        let staged = cache.appendingPathComponent("\(bundleName)/Claude.app/Contents")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2048).write(to: staged.appendingPathComponent("payload"))
        // ShipIt writes JSON despite the `.plist` extension.
        let state = #"{"updateBundleURL":"file://\#(cache.path)/\#(bundleName)/Claude.app/"}"#
        try Data(state.utf8).write(to: URL(fileURLWithPath: scene.statePath))
        return cache.appendingPathComponent(bundleName)
    }

    @Test
    func clearsTheArmedJobAndTheBundleItPointsAt() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let staged = try armJob(scene)

        let outcome = SquirrelResidue(statePath: scene.statePath).sweep()

        #expect(outcome.clearedArmedJob)
        #expect(outcome.removedStagedBundles == ["update.MxqCNfY"])
        #expect(outcome.reclaimedBytes >= 2048)
        #expect(!fm.fileExists(atPath: staged.path))
        #expect(!fm.fileExists(atPath: scene.statePath))
    }

    /// ShipIt can leave more than one behind — each failed attempt stages its own.
    @Test
    func clearsEveryStagedBundle() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        _ = try armJob(scene, bundleName: "update.aaa")
        _ = try armJob(scene, bundleName: "update.bbb")

        let outcome = SquirrelResidue(statePath: scene.statePath).sweep()

        #expect(outcome.removedStagedBundles.sorted() == ["update.aaa", "update.bbb"])
    }

    /// The sweep is narrow on purpose: this is Claude's cache directory, not ours, and
    /// anything that is not an armed job or a staging directory is somebody else's.
    @Test
    func leavesEverythingElseInThatDirectoryAlone() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let cache = URL(fileURLWithPath: scene.statePath).deletingLastPathComponent()
        try Data("log".utf8).write(to: cache.appendingPathComponent("ShipIt_stderr.log"))
        try Data("x".utf8).write(to: cache.appendingPathComponent("something-else"))
        _ = try armJob(scene)

        _ = SquirrelResidue(statePath: scene.statePath).sweep()

        #expect(fm.fileExists(atPath: cache.appendingPathComponent("ShipIt_stderr.log").path))
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("something-else").path))
    }

    /// Safe to run when there is nothing to do — it runs on every reconcile.
    @Test
    func reportsNoChangeWhenThereIsNothingToClear() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }

        let outcome = SquirrelResidue(statePath: scene.statePath).sweep()

        #expect(!outcome.changedAnything)
        #expect(outcome.reclaimedBytes == 0)
    }

    @Test
    func survivesACacheDirectoryThatIsNotThere() {
        let missing = fm.temporaryDirectory
            .appendingPathComponent("cm-absent-\(UUID().uuidString)/ShipItState.plist")

        let outcome = SquirrelResidue(statePath: missing.path).sweep()

        #expect(!outcome.changedAnything)
    }
}

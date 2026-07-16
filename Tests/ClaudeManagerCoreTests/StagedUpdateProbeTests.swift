import Foundation
import Testing
@testable import ClaudeManagerCore

struct StagedUpdateProbeTests {
    let fm = FileManager.default

    struct Scene {
        let root: URL
        let real: RealClaude
        var shipItStatePath: String {
            root.appendingPathComponent("ShipItState.plist").path
        }

        var stagedBundle: URL {
            root.appendingPathComponent("update.XXXX/Claude.app")
        }
    }

    /// A fake install (`real`, version 9.9.9 via `makeFakeRealApp`) under a temp root.
    func makeScene() throws -> Scene {
        let root = try Fixture.makeTempDir()
        let real = try Fixture.makeFakeRealApp(in: root, iconData: Data("x".utf8))
        return Scene(root: root, real: real)
    }

    /// Write a minimal staged `.app` with the given version, and a ShipItState.plist
    /// (JSON) pointing at it.
    func arm(_ scene: Scene, stagedVersion: String) throws {
        let contents = scene.stagedBundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": stagedVersion]
        try PropertyListSerialization
            .data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let state: [String: Any] = [
            "bundleIdentifier": "com.anthropic.claudefordesktop",
            "targetBundleURL": scene.real.appURL.absoluteString,
            "updateBundleURL": scene.stagedBundle.absoluteString
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: URL(fileURLWithPath: scene.shipItStatePath))
    }

    func probe(_ scene: Scene) -> StagedUpdateProbe {
        StagedUpdateProbe(realClaude: scene.real, shipItStatePath: scene.shipItStatePath, fileManager: fm)
    }

    @Test
    func detectsNewerStagedBundle() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try arm(scene, stagedVersion: "9.9.10") // installed is 9.9.9

        let staged = try #require(probe(scene).probe())
        #expect(staged.stagedVersion == "9.9.10")
        #expect(staged.installedVersion == "9.9.9")
        #expect(staged.stagedBundleURL.path == scene.stagedBundle.path)
        #expect(staged.isUpgrade)
    }

    @Test
    func detectsStagedBundleGivenPlainPath() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try arm(scene, stagedVersion: "9.9.10")
        // Rewrite the state with updateBundleURL as a plain absolute path (no `file://`),
        // which `URL(string:)` wouldn't treat as a file URL — the fallback must still find it.
        let state: [String: Any] = ["updateBundleURL": scene.stagedBundle.path]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: URL(fileURLWithPath: scene.shipItStatePath))

        let staged = try #require(probe(scene).probe())
        #expect(staged.stagedVersion == "9.9.10")
        #expect(staged.stagedBundleURL.path == scene.stagedBundle.path)
    }

    @Test
    func noStateFileYieldsNil() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        #expect(probe(scene).probe() == nil)
    }

    @Test
    func reStageOfSameVersionIsNotOffered() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try arm(scene, stagedVersion: "9.9.9") // same as installed
        #expect(probe(scene).probe() == nil)
    }

    @Test
    func olderRollbackBundleIsNotOffered() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try arm(scene, stagedVersion: "9.9.8") // older than installed
        #expect(probe(scene).probe() == nil)
    }

    @Test
    func missingStagedBundleYieldsNil() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try arm(scene, stagedVersion: "9.9.10")
        try fm.removeItem(at: scene.stagedBundle) // GC'd after arming
        #expect(probe(scene).probe() == nil)
    }

    @Test
    func malformedStateYieldsNil() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: scene.shipItStatePath))
        #expect(probe(scene).probe() == nil)
    }
}

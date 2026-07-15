import Foundation
import Testing
@testable import ClaudeManagerCore

/// End-to-end checks against the *real* Claude.app on this machine — the real
/// LaunchServices lookup and the real `electron.icns` badge pipeline. Opt-in only:
/// set `CLAUDE_MANAGER_LIVE=1` to run. Always installs into a temp directory and
/// never touches `/Applications`, never launches Claude.
struct LiveIntegrationTests {
    static var live: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_MANAGER_LIVE"] == "1"
    }

    @Test(.enabled(if: LiveIntegrationTests.live))
    func addsRealLauncherWithGenuineBadge() throws {
        let fm = FileManager.default
        let real = try RealClaudeLocator().locate()
        let root = try Fixture.makeTempDir()
        defer {
            try? fm.removeItem(at: root)
            Fixture.purgeTrash(displayNamePrefix: "Claude CMLIVE")
        }
        let installDir = root.appendingPathComponent("apps")
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Stub only process/Dock tools; iconutil + real icon extraction run for real.
        let runner = RecordingCommandRunner.delegating(stub: idleStub)
        let store = ProfileStore(
            realClaude: real,
            configuration: ProfileStoreConfiguration(
                installDirectory: installDir,
                defaultProfilesDirectory: root.appendingPathComponent("profiles"),
                // Keep `list()`'s staged-update probe off the host's real ShipIt cache.
                shipItStatePath: root.appendingPathComponent("ShipItState.plist").path
            ),
            runner: runner,
            signalSender: { _, _ in 0 }
        )

        let result = try store.add(AddProfileRequest(name: "cmlive", label: "LV", color: .named("purple")))
        let appURL = URL(fileURLWithPath: result.profile.appPath)

        // Launcher script points at the real, signed binary.
        let script = try String(
            contentsOf: appURL.appendingPathComponent("Contents/MacOS/launcher"),
            encoding: .utf8
        )
        #expect(script.contains(real.binaryURL.path))

        // Badge is a genuine, non-trivial .icns built from the real icon.
        let icns = try Data(contentsOf: appURL.appendingPathComponent("Contents/Resources/Badge.icns"))
        #expect(icns.prefix(4) == Data("icns".utf8))
        #expect(icns.count > 10000)

        // Marker round-trips through a fresh scan.
        let listed = store.list()
        #expect(listed.contains { $0.profile.name == "cmlive" })

        _ = try store.remove(result.profile, purgeProfile: true)
        #expect(!fm.fileExists(atPath: result.profile.appPath))
    }
}

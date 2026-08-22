import Foundation
import Testing
@testable import ClaudeManagerCore

/// Doctor rows about a staged Claude update and the installer behind it. Split from
/// `DoctorTests` because this failure mode has its own machinery — an armed ShipIt job,
/// a live installer process, and that process's own log — and none of it overlaps the
/// launcher/orphan checks that file covers.
struct DoctorStagedUpdateTests {
    let fm = FileManager.default

    /// Arm a staged newer bundle (`stagedVersion`) referenced by the scene's ShipItState.
    private func armStagedUpdate(_ scene: DoctorScene, stagedVersion: String) throws {
        let bundle = scene.root.appendingPathComponent("update.X/Claude.app")
        let contents = bundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization
            .data(fromPropertyList: ["CFBundleShortVersionString": stagedVersion], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try JSONSerialization
            .data(withJSONObject: ["updateBundleURL": bundle.absoluteString])
            .write(to: URL(fileURLWithPath: scene.shipItStatePath))
    }

    @Test
    func warnsWhenUpdateStagedButNotApplied() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try armStagedUpdate(scene, stagedVersion: "9.9.10") // installed is 9.9.9

        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("staged but not applied")
        })
    }

    @Test
    func noStagedUpdateNoWarning() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains { $0.title.contains("staged but not applied") })
    }

    /// A runner where ShipIt is alive with the given age in seconds.
    private func installerRunning(forSeconds age: Int) -> RecordingCommandRunner {
        RecordingCommandRunner { executable, args in
            if executable == CoreConstants.pgrepPath, args.last?.contains("/ShipIt ") == true {
                return CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
            }
            if executable == CoreConstants.psPath, args.contains("etimes=") {
                return CommandOutput(exitCode: 0, standardOutput: "\(age)\n", standardError: "")
            }
            return idleStub(executable, args)
        }
    }

    @Test
    func warnsWhenTheInstallerHasBeenWaitingFarTooLong() throws {
        // ShipIt waits for zero instances indefinitely and says so nowhere. A swap is 3–5 s,
        // so an installer measured in minutes is blocked, not working.
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        let diags = runDoctor(scene, runner: installerRunning(forSeconds: 1800))
        #expect(diags.contains {
            $0.severity == .warning && $0.title.contains("installer has been waiting 30 min")
        })
    }

    @Test
    func aFreshInstallerIsNotReported() throws {
        // A swap in progress is normal — only a stuck one is news.
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        let diags = runDoctor(scene, runner: installerRunning(forSeconds: 4))
        #expect(!diags.contains { $0.title.contains("installer has been waiting") })
    }

    @Test
    func surfacesWhyTheLastAttemptFailedWhileSomethingIsStillArmed() throws {
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try armStagedUpdate(scene, stagedVersion: "9.9.10")
        try "2026-08-19 13:48:55.843 ShipIt[3:4] Aborting update attempt because there are 2 "
            .appending("running instances of the target app\n")
            .write(
                toFile: CoreConstants.shipItStderrPath(forStatePath: scene.shipItStatePath),
                atomically: true,
                encoding: .utf8
            )

        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(diags.contains {
            $0.severity == .warning
                && $0.title.contains("last install attempt didn't complete")
                && ($0.detail?.contains("was running while ShipIt") ?? false)
        })
    }

    @Test
    func staleFailuresAreSilentWhenNothingIsArmed() throws {
        // The log is append-only and never rotated, so its tail always holds old failures.
        // With no armed update there is nothing the user is living with — say nothing.
        let scene = try makeDoctorScene()
        defer { try? fm.removeItem(at: scene.root) }
        try "2026-08-01 10:00:00.000 ShipIt[1:2] Too many attempts to install, aborting update\n"
            .write(
                toFile: CoreConstants.shipItStderrPath(forStatePath: scene.shipItStatePath),
                atomically: true,
                encoding: .utf8
            )

        let diags = runDoctor(scene, runner: RecordingCommandRunner(handler: idleStub))
        #expect(!diags.contains { $0.title.contains("last install attempt") })
    }
}

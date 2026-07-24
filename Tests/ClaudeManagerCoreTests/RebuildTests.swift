import Foundation
import Testing
@testable import ClaudeManagerCore

/// Launcher rebuild and wrapper-version staleness behaviour.
struct LauncherRebuildTests {
    let fm = FileManager.default

    @Test
    func rebuildRestampsCurrentWrapperVersionAndArchKey() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try setWrapperVersion(1, atAppPath: profile.appPath)
        #expect(env.store.list().first?.needsRebuild == true)

        try env.store.rebuild(profile)

        let listed = env.store.list()
        #expect(listed.first?.needsRebuild == false)
        #expect(listed.first?.wrapperVersion == CoreConstants.currentWrapperVersion)
        // The regenerated Info.plist carries the native-arch key.
        let info = try #require(RealClaude.plist(
            at: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Info.plist")
        ))
        #expect(info["LSArchitecturePriority"] as? [String] == ["arm64", "x86_64"])
    }

    @Test
    func rebuildRefusesWhileRunning() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        #expect(throws: ClaudeManagerError.self) {
            try env.store.rebuild(profile)
        }
    }

    @Test
    func rebuildAllSkipsRunningRebuildsRest() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let running = try env.store.add(AddProfileRequest(name: env.name("running"))).profile
        _ = try env.store.add(AddProfileRequest(name: env.name("stopped")))
        // Report only the "running" profile's user-data-dir as live (its unique name
        // appears in the pgrep pattern; the name has no regex metacharacters). Keep
        // delegating iconutil to the real system so the "stopped" rebuild's icon packs.
        let runningName = env.name("running")
        let system = SystemCommandRunner()
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.iconutilPath {
                return (try? system.run(executable, args))
                    ?? CommandOutput(exitCode: 1, standardOutput: "", standardError: "delegate failed")
            }
            if executable == CoreConstants.pgrepPath {
                let live = (args.last ?? "").contains(runningName)
                return CommandOutput(
                    exitCode: live ? 0 : 1, standardOutput: live ? "777\n" : "", standardError: ""
                )
            }
            return idleStub(executable, args)
        }
        let result = try env.store.rebuildAll()
        #expect(result.rebuilt.map(\.name) == [env.name("stopped")])
        #expect(result.skippedRunning.map(\.name) == [running.name])
        #expect(result.failed.isEmpty)
    }

    @Test
    func rebuildAllRecordsFailuresWithoutAborting() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // Build both launchers with the real iconutil, then break icon generation so
        // every subsequent rebuild fails — the batch must still complete and report
        // both as failed rather than throwing on the first.
        _ = try env.store.add(AddProfileRequest(name: env.name("one")))
        _ = try env.store.add(AddProfileRequest(name: env.name("two")))
        // Keep `codesign` real (a rebuild that reaches signing must still sign for
        // real), but stop delegating `iconutil` so it can be made to fail.
        env.runner.setDelegated([CoreConstants.codesignPath])
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.iconutilPath {
                return CommandOutput(exitCode: 1, standardOutput: "", standardError: "boom")
            }
            return idleStub(executable, args)
        }
        let result = try env.store.rebuildAll()
        #expect(result.rebuilt.isEmpty)
        #expect(result.skippedRunning.isEmpty)
        #expect(Set(result.failed.map(\.profile.name)) == [env.name("one"), env.name("two")])
        // Nothing rebuilt → no batch Dock restart.
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    /// The soft "older launcher format" warning is reserved for launchers that still
    /// run. Every version below `minimumRunnableWrapperVersion` is reported as an error
    /// instead (see `LauncherSigningTests`), so with the two constants currently equal
    /// no launcher can be stale-but-runnable — this pins that rule rather than the
    /// wording of either message.
    @Test
    func staleWrapperVersionsBelowTheRunnableFloorAreNotJustAWarning() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try setWrapperVersion(1, atAppPath: profile.appPath)

        let diagnostics = env.store.doctor()

        #expect(!diagnostics.contains { $0.title.contains("older launcher format") })
        #expect(diagnostics.contains { $0.severity == .error && $0.title.contains("macOS will not run it") })
    }
}

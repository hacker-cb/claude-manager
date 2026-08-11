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

    /// The core of the flicker fix: rebuilding with the same label/color/style regenerates
    /// a byte-identical badge, so no Dock refresh is pending and the screen-flashing restart
    /// is never issued. Also pins that the icon pipeline is deterministic — if it weren't,
    /// every rebuild would report a spurious change and this would fail.
    @Test
    func rebuildOfUnchangedLauncherReportsNoPendingRefreshAndNeverFlashes() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        let pending = try env.store.rebuild(profile)
        #expect(pending == false)
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    /// The opt-in "Refresh Dock now" restarts the Dock via `IconCache.restartDock()` — the
    /// one path that flashes the screen. It depends only on the CommandRunner, not on a
    /// located Claude.app, so the app can invoke it directly.
    ///
    /// The order is asserted, not just the pair: the Dock renders nothing itself, it asks
    /// `iconservicesagent`, so restarting the Dock first would only bring it back to a
    /// cache still holding the old badge.
    @Test
    func restartDockDropsTheIconAgentBeforeRestartingTheDock() {
        let runner = RecordingCommandRunner()
        IconCache(runner: runner).restartDock()
        #expect(runner.invocations(of: CoreConstants.killallPath).map(\.arguments)
            == [["iconservicesagent"], ["Dock"]])
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
        // Stop delegating `iconutil` so it can be made to fail.
        env.runner.setDelegated([])
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

    @Test
    func rebuildAllReportsPendingWhenTheBadgeStyleChanged() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        _ = try env.store.add(AddProfileRequest(name: env.name("home")))
        // The "Apply to all launchers" path: a second store over the same install dir with a
        // different badge style. Every badge re-renders differently, so the batch reports a
        // pending Dock refresh — still opt-in, so it never restarts the Dock itself.
        var restyled = BadgeStyle.default
        restyled.shape = BadgeStyle.Shape.allCases.first { $0 != restyled.shape } ?? restyled.shape
        let restyledStore = ProfileStore(
            realClaude: env.real,
            configuration: ProfileStoreConfiguration(
                installDirectory: env.installDir,
                defaultProfilesDirectory: env.profilesDir,
                badgeStyle: restyled,
                managedPreferencesURLs: env.managedPreferencesURLs,
                defaultProfileUserDataPath: env.defaultProfileUserDataPath,
                shipItStatePath: env.shipItStatePath
            ),
            runner: env.runner,
            signalSender: { _, _ in 0 }
        )
        let result = try restyledStore.rebuildAll()
        #expect(Set(result.rebuilt.map(\.name)) == [env.name("work"), env.name("home")])
        #expect(result.dockRefreshPending == true)
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

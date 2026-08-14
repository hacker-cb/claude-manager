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
        let result = try env.store.rebuild(profile)
        #expect(!result.iconChanged)
        #expect(result.liveRewrite == nil) // stopped profile — nothing to restart
        #expect(env.runner.invocations(of: CoreConstants.killallPath).isEmpty)
    }

    /// The opt-in "Refresh Dock now" restarts the Dock via `IconCache.restartDock()` — the
    /// one path that flashes the screen. It depends only on the CommandRunner, not on a
    /// located Claude.app, so the app can invoke it directly.
    ///
    /// The order is asserted, not just the pair: the Dock renders nothing itself, it asks
    /// `iconservicesagent`, so restarting the Dock first would only hand it back to a live
    /// process holding the old render.
    @Test
    func restartDockDropsTheIconAgentBeforeRestartingTheDock() {
        let runner = RecordingCommandRunner { executable, _ in
            // pgrep exits non-zero when nothing matched: the agent is already gone, so the
            // wait returns at once.
            let gone = executable == CoreConstants.pgrepPath
            return CommandOutput(exitCode: gone ? 1 : 0, standardOutput: "", standardError: "")
        }
        IconCache(runner: runner).restartDock()
        #expect(runner.invocations(of: CoreConstants.killallPath).map(\.arguments)
            == [["iconservicesagent"], ["Dock"]])
    }

    /// `killall` only *sends* SIGTERM, and macOS has no `-w`, so `restartDock` polls for the
    /// agent to actually exit — otherwise the Dock relaunches into a live agent still
    /// holding the old render. The wait is bounded: an agent that never dies must delay the
    /// refresh, never hang it, so the Dock is still restarted once the budget is spent.
    @Test
    func restartDockWaitsForTheIconAgentButNeverHangsOnIt() {
        // Every probe exits 0 with a pid: pgrep keeps reporting the agent alive — the
        // wedged-agent case.
        let runner = RecordingCommandRunner { _, _ in
            CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
        }
        IconCache(runner: runner, agentExitAttempts: 3, agentExitInterval: 0).restartDock()
        #expect(runner.invocations(of: CoreConstants.pgrepPath).count == 3)
        // The budget is spent, and the Dock is restarted anyway.
        #expect(runner.invocations(of: CoreConstants.killallPath).map(\.arguments)
            == [["iconservicesagent"], ["Dock"]])
    }

    /// A running profile is rebuilt, not refused. The launcher is a script that `exec`s the
    /// real binary, so the live process holds nothing in the bundle — and refusing here
    /// would put a wrapper bump out of reach of any profile the user keeps open. What the
    /// rebuild cannot reach is the running window, so it reports the pid instead.
    @Test
    func rebuildRunsUnderALiveInstanceAndReportsIt() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        var profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        // `makeStoreEnv` already delegates iconutil to the real system, so the handler only
        // has to answer the pgrep probe.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        // Change the badge, or the rebuild is byte-identical and correctly says there is
        // nothing to restart for (see `rebuildOfAnUnchangedLauncherNeverNudgesForARestart`).
        profile.label = "ZZ"
        let result = try env.store.rebuild(profile)
        #expect(result.iconChanged)
        #expect(result.liveRewrite == LiveRewrite(profile: profile, pid: 888))
        // The bundle really was rewritten, not skipped.
        #expect(LauncherBundle().readMarker(at: profile.appURL)?.marker.label == "ZZ")
    }

    /// The nudge has to answer "would a restart reveal anything", not "is it running". A
    /// rebuild regenerates from the bundle's own marker, so it cannot change the window's
    /// name; when the badge comes out byte-identical too — which is what "Apply to all
    /// launchers" does to already-current launchers — a nudge would ask the user to close a
    /// live session to reveal a change that does not exist.
    @Test
    func rebuildOfAnUnchangedLauncherNeverNudgesForARestart() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let profile = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                return CommandOutput(exitCode: 0, standardOutput: "888\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        let result = try env.store.rebuild(profile)
        #expect(!result.iconChanged)
        #expect(result.liveRewrite == nil)
    }

    /// The batch no longer skips a running launcher: skipping is what left an always-open
    /// profile behind on every wrapper bump. Both are rebuilt; the live one is reported so
    /// the app can nudge just that profile for a restart.
    @Test
    func rebuildAllRebuildsRunningLaunchersAndReportsThem() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let running = try env.store.add(AddProfileRequest(name: env.name("running"))).profile
        _ = try env.store.add(AddProfileRequest(name: env.name("stopped")))
        // Report only the "running" profile's user-data-dir as live (its unique name
        // appears in the pgrep pattern; the name has no regex metacharacters).
        let runningName = env.name("running")
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                let live = (args.last ?? "").contains(runningName)
                return CommandOutput(
                    exitCode: live ? 0 : 1, standardOutput: live ? "777\n" : "", standardError: ""
                )
            }
            return idleStub(executable, args)
        }
        // Restyle, as "Apply to all launchers" does — otherwise every badge re-renders
        // byte-identically and the batch rightly reports nothing to restart for.
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
        #expect(Set(result.rebuilt.map(\.name)) == [env.name("running"), env.name("stopped")])
        // Only the live one is nudged, and only because its badge really changed.
        #expect(result.liveRewrites.map(\.profile.name) == [running.name])
        #expect(result.liveRewrites.map(\.pid) == [777])
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
        #expect(result.liveRewrites.isEmpty)
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

    /// An unlistable install directory scans as "no launchers", and a batch over that reports
    /// success having rebuilt nothing — while every launcher stays on the old wrapper, which is
    /// exactly what this operation exists to fix.
    @Test(.enabled(if: getuid() != 0, "needs a non-root user for permission bits to bite"))
    func rebuildAllRefusesWhenTheInstallDirectoryCannotBeListed() throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.installDir.path)
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        try fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: env.installDir.path)

        let thrown = try #require(throws: ClaudeManagerError.self) {
            try env.store.rebuildAll()
        }

        #expect(try #require(thrown.errorDescription).contains("could not be read"))
    }

    /// An install directory that simply is not there yet — an override pointed somewhere new —
    /// is a state the store creates on demand, and there is genuinely nothing to rebuild. Only
    /// a folder that exists and cannot be listed hides launchers from the batch.
    @Test
    func rebuildAllIsANoOpWhenTheInstallDirectoryDoesNotExistYet() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try fm.removeItem(at: env.installDir)

        let result = try env.store.rebuildAll()

        #expect(result.rebuilt.isEmpty)
        #expect(result.failed.isEmpty)
    }
}

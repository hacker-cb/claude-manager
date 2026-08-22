import Foundation
import Testing
@testable import ClaudeManagerCore

/// Gate 2 of the staged-update apply: waiting the swap out by watching ShipIt rather
/// than a clock. Kept apart from `ProfileStoreStagedUpdateTests` (which covers the
/// quiesce, the abort paths and the relaunch rules) because these all turn on one
/// thing — what the installer process is doing while we wait.
struct ProfileStoreStagedUpdateGateTests {
    let fm = FileManager.default

    @Test
    func reportsSwapDidNotCompleteWhenNoInstallerEverAppears() async throws {
        let env = try makeStoreEnv() // idle → quiesce immediate, ShipIt absent, version stays 9.9.9
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The grace window bounds this: with no installer to wait for, the apply must fail
        // in a few polls rather than parking on the full ten-minute backstop.
        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 600, shipItGracePolls: 2
        )
        #expect(result.outcome == .swapDidNotComplete(stagedVersion: "9.9.10", reason: nil))
    }

    @Test
    func surfacesWhatShipItLoggedForThisAttempt() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")
        let log = URL(fileURLWithPath: CoreConstants.shipItStderrPath(forStatePath: env.shipItStatePath))
        try "2026-08-19 13:48:55.843 ShipIt[3:4] Aborting update attempt because there are 2 "
            .appending("running instances of the target app\n")
            .write(to: log, atomically: true, encoding: .utf8)

        // Written *before* the apply, so it sits behind the recorded offset: this attempt
        // logged nothing, and a stale line must not be dressed up as its reason.
        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 10, shipItGracePolls: 1
        )
        #expect(result.outcome == .swapDidNotComplete(stagedVersion: "9.9.10", reason: nil))
    }

    @Test
    func waitsOutAnInstallerThatRunsFarPastAnyFixedTimeout() async throws {
        // The regression this whole change exists for: the swap took 57 s on a bundle that
        // normally takes 4, the old 30-poll timer gave up, relaunched, and ShipIt aborted
        // the install it was in the middle of. While ShipIt lives, we wait.
        let probes = CallCounter()
        let env = try makeStoreEnv(stub: { executable, args in
            if executable == CoreConstants.pgrepPath, args.last?.contains("/ShipIt ") == true {
                // Alive for the first 20 probes — well past the old 30-second budget's
                // equivalent here — then gone.
                return probes.next() <= 20
                    ? CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                    : CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
            return idleStub(executable, args)
        })
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The version only flips once the installer has been alive a while — a swap that
        // lands late still counts as applied.
        let infoURL = env.real.infoPlistURL
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(120))
            var info = RealClaude.plist(at: infoURL) ?? [:]
            info["CFBundleShortVersionString"] = "9.9.10"
            try? PropertyListSerialization
                .data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: infoURL)
        }
        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 600, shipItGracePolls: 2
        )
        _ = await flip.value
        #expect(result.outcome == .applied(from: "9.9.9", to: "9.9.10"))
    }

    @Test
    func leavesProfilesClosedWhileTheInstallerIsStillWorking() async throws {
        // Relaunching mid-install is exactly what makes ShipIt abort, so when the backstop
        // elapses with the installer still alive, the set stays closed and says so.
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let clone = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The clone is running at snapshot and quits (pgrep: running once, gone after), so
        // Gate 1 passes and there is genuinely something to reopen — while the installer
        // stays alive throughout, which is the only thing that must keep it closed.
        let counter = CallCounter()
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath {
                if args.last?.contains("/ShipIt ") == true {
                    return CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                }
                let running = counter.next() == 1
                return CommandOutput(
                    exitCode: running ? 0 : 1, standardOutput: running ? "555\n" : "", standardError: ""
                )
            }
            return idleStub(executable, args)
        }

        let result = await env.store.applyStagedUpdateToAll(
            stopPollInterval: 0.01, stopMaxPolls: 2,
            swapPollInterval: 0.01, swapMaxPolls: 3, shipItGracePolls: 1
        )
        #expect(result.outcome == .swapStillInstalling(stagedVersion: "9.9.10"))
        #expect(result.relaunched.isEmpty)
        // The clone WAS in the snapshot and is down — only the still-installing guard keeps
        // it closed, so this fails if that guard is dropped.
        #expect(!env.runner.invocations(of: CoreConstants.openPath)
            .contains { $0.arguments.contains(clone.appPath) })
    }

    @Test
    func doesNotRelaunchUntilTheInstallerHasActuallyExited() async throws {
        // The swap lands before ShipIt is done — it still cleans up and hands off (~280 ms
        // measured). Returning at the version change alone would relaunch inside that tail,
        // breaking the invariant the gate exists for, so success drains until it is gone.
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The installer stays alive for 6 probes; the swap lands almost immediately, so
        // every probe after the first sees "version done, installer still working".
        let probes = CallCounter()
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath, args.last?.contains("/ShipIt ") == true {
                return probes.next() <= 6
                    ? CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                    : CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
            return idleStub(executable, args)
        }
        let infoURL = env.real.infoPlistURL
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            var info = RealClaude.plist(at: infoURL) ?? [:]
            info["CFBundleShortVersionString"] = "9.9.10"
            try? PropertyListSerialization
                .data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: infoURL)
        }

        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 600, shipItGracePolls: 1, swapDrainPolls: 30
        )
        _ = await flip.value
        #expect(result.outcome == .applied(from: "9.9.9", to: "9.9.10"))
        // It kept probing until the installer was gone rather than returning at the swap:
        // the run consumed all 6 "alive" answers plus the "gone" one that ended it.
        #expect(probes.next() > 7)
    }

    @Test
    func stopsDrainingWhenTheInstallerLingersPastTheSwap() async throws {
        // The bundle is in place, so an installer that never exits is no reason to keep the
        // user's profiles closed forever — the drain is bounded.
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // An installer that never exits — without a bounded drain this would sit on the
        // full backstop and report `swapStillInstalling` for a swap that already landed.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath, args.last?.contains("/ShipIt ") == true {
                return CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
            }
            return idleStub(executable, args)
        }
        let infoURL = env.real.infoPlistURL
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            var info = RealClaude.plist(at: infoURL) ?? [:]
            info["CFBundleShortVersionString"] = "9.9.10"
            try? PropertyListSerialization
                .data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: infoURL)
        }

        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 600, shipItGracePolls: 1, swapDrainPolls: 3
        )
        _ = await flip.value
        #expect(result.outcome == .applied(from: "9.9.9", to: "9.9.10"))
    }

    @Test
    func carriesShipItsOwnReasonIntoTheOutcome() async throws {
        // The reason has to survive the whole path: ShipIt's log → probe → outcome. The
        // offset is taken before the apply, so a line written during it belongs to it.
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        let log = CoreConstants.shipItStderrPath(forStatePath: env.shipItStatePath)
        let probes = CallCounter()
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.pgrepPath, args.last?.contains("/ShipIt ") == true {
                if probes.next() == 1 {
                    return CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
                }
                // On its way out it writes the abort, as a real failed attempt does.
                try? "2026-08-19 13:48:55.843 ShipIt[3:4] Aborting update attempt because there "
                    .appending("are 2 running instances of the target app\n")
                    .write(toFile: log, atomically: true, encoding: .utf8)
                return CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
            return idleStub(executable, args)
        }

        let result = await env.store.applyStagedUpdateToAll(
            swapPollInterval: 0.01, swapMaxPolls: 20, shipItGracePolls: 2
        )
        guard case let .swapDidNotComplete(version, reason) = result.outcome else {
            Issue.record("expected swapDidNotComplete, got \(result.outcome)")
            return
        }
        #expect(version == "9.9.10")
        #expect(reason?.contains("was running while ShipIt") == true)
    }
}

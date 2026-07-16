import Foundation
import Testing
@testable import ClaudeManagerCore

struct ProfileStoreStagedUpdateTests {
    let fm = FileManager.default

    /// Arm a staged newer bundle referenced by the env's ShipItState path.
    private func armStagedUpdate(_ env: StoreEnv, stagedVersion: String) throws {
        let bundle = env.root.appendingPathComponent("update.X/Claude.app")
        let contents = bundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization
            .data(fromPropertyList: ["CFBundleShortVersionString": stagedVersion], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try JSONSerialization
            .data(withJSONObject: ["updateBundleURL": bundle.absoluteString])
            .write(to: URL(fileURLWithPath: env.shipItStatePath))
    }

    @Test
    func noStagedUpdateWhenNothingArmed() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let result = await env.store.applyStagedUpdateToAll()
        #expect(result.outcome == .noStagedUpdate)
        #expect(result.relaunched.isEmpty)
    }

    @Test
    func appliesWhenNothingRunningAndVersionFlips() async throws {
        let env = try makeStoreEnv() // idleStub → no running instances
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10") // installed 9.9.9

        // Simulate ShipIt swapping the app in shortly after the quiesce. Capture only the
        // Sendable URL (not self/env) so the detached task is data-race-free.
        let infoURL = env.real.infoPlistURL
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            var info = RealClaude.plist(at: infoURL) ?? [:]
            info["CFBundleShortVersionString"] = "9.9.10"
            try? PropertyListSerialization
                .data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: infoURL)
        }
        let result = await env.store.applyStagedUpdateToAll(swapPollInterval: 0.02, swapMaxPolls: 300)
        _ = await flip.value
        #expect(result.outcome == .applied(from: "9.9.9", to: "9.9.10"))
    }

    @Test
    func abortsWhenAnInstanceWillNotQuit() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")
        // A default main that never exits (ps always reports it); no clones (pgrep idle).
        let realBin = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(
                    exitCode: 0,
                    standardOutput: "  501     1 \(realBin)\n",
                    standardError: ""
                )
            }
            return idleStub(executable, args)
        }

        let result = await env.store.applyStagedUpdateToAll(stopPollInterval: 0.01, stopMaxPolls: 2)
        guard case let .instancesStillRunning(names) = result.outcome else {
            Issue.record("expected instancesStillRunning, got \(result.outcome)")
            return
        }
        #expect(names == ["default account"])
        // The still-running default can't be reopened (would duplicate it); nothing else
        // was closed, so nothing is relaunched.
        #expect(result.relaunched.isEmpty)
    }

    @Test
    func claudeManagerOwnProcessDoesNotBlockTheGate() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")
        // ps reports Claude Manager's OWN main (path contains "Claude" but isn't the real
        // binary) — it must NOT count toward the swap gate, or the apply could never pass.
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(
                    exitCode: 0,
                    standardOutput: "  777     1 /Applications/Claude Manager.app/Contents/MacOS/Claude Manager\n",
                    standardError: ""
                )
            }
            return idleStub(executable, args)
        }
        let infoURL = env.real.infoPlistURL
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            var info = RealClaude.plist(at: infoURL) ?? [:]
            info["CFBundleShortVersionString"] = "9.9.10"
            try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: infoURL)
        }
        let result = await env.store.applyStagedUpdateToAll(swapPollInterval: 0.02, swapMaxPolls: 300)
        _ = await flip.value
        #expect(result.outcome == .applied(from: "9.9.9", to: "9.9.10"))
    }

    @Test
    func abortRelaunchesAccountsThatAlreadyStopped() async throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let clone = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The clone is running at snapshot then quits (pgrep: running once, gone after);
        // a real-binary default keeps blocking the swap (ps always reports it).
        let realBin = env.real.binaryURL.path
        let counter = CallCounter()
        env.runner.setHandler { executable, _ in
            if executable == CoreConstants.pgrepPath {
                let running = counter.next() == 1
                return CommandOutput(
                    exitCode: running ? 0 : 1, standardOutput: running ? "555\n" : "", standardError: ""
                )
            }
            if executable == CoreConstants.psPath {
                return CommandOutput(
                    exitCode: 0,
                    standardOutput: "  501     1 \(realBin)\n",
                    standardError: ""
                )
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        let result = await env.store.applyStagedUpdateToAll(stopPollInterval: 0.01, stopMaxPolls: 3)
        guard case .instancesStillRunning = result.outcome else {
            Issue.record("expected instancesStillRunning, got \(result.outcome)")
            return
        }
        // The clone that quit is reopened; the still-running default is not.
        #expect(result.relaunched == [clone.displayName])
    }

    @Test
    func abortReportsBlockersCapturedBeforeRelaunch() async throws {
        let env = try makeStoreEnv()
        defer {
            try? fm.removeItem(at: env.root)
            Fixture.purgeTrash(displayNamePrefix: env.display("work"))
        }
        let clone = try env.store.add(AddProfileRequest(name: env.name("work"))).profile
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        // The clone runs at snapshot then quits (pgrep: running once, gone after). An
        // *external*, unmanaged real-Claude instance keeps blocking the swap forever, so the
        // apply aborts. The relaunched clone becomes ps-visible only AFTER we reopen it — so a
        // blocker list captured after relaunch would wrongly include it.
        let realBin = env.real.binaryURL.path
        let cloneProfile = clone.profilePath
        let cloneAppPath = clone.appPath
        let pgrep = CallCounter()
        let runner = env.runner
        env.runner.setHandler { executable, _ in
            if executable == CoreConstants.pgrepPath {
                let running = pgrep.next() == 1
                return CommandOutput(
                    exitCode: running ? 0 : 1, standardOutput: running ? "555\n" : "", standardError: ""
                )
            }
            if executable == CoreConstants.psPath {
                var out = "  900     1 \(realBin) --user-data-dir=/external\n"
                // Once relaunchSnapshot has reopened the clone (open -n <clone>.app) it too
                // shows up in `ps` — the exact case the ordering fix must exclude.
                let cloneRelaunched = runner.invocations(of: CoreConstants.openPath)
                    .contains { $0.arguments.contains(cloneAppPath) }
                if cloneRelaunched {
                    out += "  555     1 \(realBin) --user-data-dir=\(cloneProfile)\n"
                }
                return CommandOutput(exitCode: 0, standardOutput: out, standardError: "")
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        let result = await env.store.applyStagedUpdateToAll(stopPollInterval: 0.01, stopMaxPolls: 3)
        guard case let .instancesStillRunning(names) = result.outcome else {
            Issue.record("expected instancesStillRunning, got \(result.outcome)")
            return
        }
        // Only the genuine external blocker is named — the clone we reopened is not, because
        // the names are captured before relaunch.
        #expect(!names.contains(clone.displayName))
        #expect(names == ["/external"])
        #expect(result.relaunched == [clone.displayName])
    }

    @Test
    func makeDefaultDerivesShipItPathFromBundleID() throws {
        let root = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let real = try Fixture.makeFakeRealApp(in: root, iconData: Data("x".utf8))
        // A legacy-bundle-id install writes ShipIt state under the legacy id.
        var info = RealClaude.plist(at: real.infoPlistURL) ?? [:]
        info["CFBundleIdentifier"] = "com.anthropic.claudeapp"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: real.infoPlistURL)

        let config = ProfileStoreConfiguration.makeDefault(realClaude: real)
        #expect(config.shipItStatePath.contains("com.anthropic.claudeapp.ShipIt"))
    }

    @Test
    func swapTimesOutWhenVersionNeverFlips() async throws {
        let env = try makeStoreEnv() // idle → quiesce immediate, but version stays 9.9.9
        defer { try? fm.removeItem(at: env.root) }
        try armStagedUpdate(env, stagedVersion: "9.9.10")

        let result = await env.store.applyStagedUpdateToAll(swapPollInterval: 0.01, swapMaxPolls: 3)
        #expect(result.outcome == .swapTimedOut(stagedVersion: "9.9.10"))
    }

    @Test
    func stopDefaultReturnsNotRunningWhenAbsent() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        #expect(await env.store.stopDefault() == .notRunning)
    }
}

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
        #expect(!names.isEmpty)
        #expect(result.relaunched.isEmpty) // aborted before the swap → nothing relaunched
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

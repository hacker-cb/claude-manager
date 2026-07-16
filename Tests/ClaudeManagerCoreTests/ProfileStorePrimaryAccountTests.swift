import Foundation
import Testing
@testable import ClaudeManagerCore

/// Launching and locating the primary (default-account) Claude — see
/// `ProfileStore+PrimaryAccount`.
struct ProfileStorePrimaryAccountTests {
    let fm = FileManager.default

    @Test
    func openRealForcesNewDefaultInstance() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // `-n` on the real app forces a fresh default account past LaunchServices'
        // bundle-id de-dup (which would otherwise activate a running clone).
        try env.store.openReal()
        let call = try #require(env.runner.invocations(of: CoreConstants.openPath).last)
        #expect(call.arguments == ["-n", env.real.appURL.path])
    }

    @Test
    func runningDefaultPIDDetectsFlaglessRealBinary() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let real = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                // pid 501: our real binary, no --user-data-dir → the default account.
                // pid 777: a clone of the same binary → must be ignored.
                let ps = "  501     1 \(real)\n"
                    + "  777     1 \(real) --user-data-dir=/data/clone\n"
                return CommandOutput(exitCode: 0, standardOutput: ps, standardError: "")
            }
            return idleStub(executable, args)
        }
        #expect(env.store.runningDefaultPID() == 501)
    }

    @Test
    func runningDefaultPIDIgnoresClonesAndOtherEditions() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let real = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                // A clone of our real app + a *different* edition's flagless default —
                // neither is our default account, so nothing should match.
                let ps = "  777     1 \(real) --user-data-dir=/data/clone\n"
                    + "  888     1 /Applications/Claude Beta.app/Contents/MacOS/Claude\n"
                return CommandOutput(exitCode: 0, standardOutput: ps, standardError: "")
            }
            return idleStub(executable, args)
        }
        #expect(env.store.runningDefaultPID() == nil)
    }

    @Test
    func snapshotReportsDefaultAccountPIDFromOneScan() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let real = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                let ps = "  501     1 \(real)\n"
                    + "  777     1 \(real) --user-data-dir=/data/clone\n"
                return CommandOutput(exitCode: 0, standardOutput: ps, standardError: "")
            }
            return idleStub(executable, args)
        }
        let snapshot = env.store.snapshot()
        #expect(snapshot.primaryAccount.pid == 501)
        #expect(snapshot.primaryAccount.isRunning)
        // The whole snapshot — launcher list *and* default status — comes from ONE `ps` sweep.
        #expect(env.runner.invocations(of: CoreConstants.psPath).count == 1)
    }

    @Test
    func snapshotDefaultAccountNotRunningWithoutADefault() throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let real = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                // Only a clone runs → there is no default-account instance.
                let ps = "  777     1 \(real) --user-data-dir=/data/clone\n"
                return CommandOutput(exitCode: 0, standardOutput: ps, standardError: "")
            }
            return idleStub(executable, args)
        }
        let snapshot = env.store.snapshot()
        #expect(snapshot.primaryAccount.pid == nil)
        #expect(!snapshot.primaryAccount.isRunning)
    }
}

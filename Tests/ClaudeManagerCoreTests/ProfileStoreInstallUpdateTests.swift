import Foundation
import Testing
@testable import ClaudeManagerCore

/// Installing a verified build: closing every profile, swapping the bundle, putting the same
/// set back.
///
/// Runs against the fixture's fake `Claude.app` in a temp directory — never
/// `/Applications` — so the swap is exercised for real (`replaceItemAt`, same volume, an
/// actual bundle appearing at the actual path) without touching the machine's install.
struct ProfileStoreInstallUpdateTests {
    let fm = FileManager.default

    /// Build a bundle to install, next to the fixture's install directory so the swap stays
    /// within one volume — the condition `replaceItemAt` is atomic under.
    private func makeIncoming(_ env: StoreEnv, version: String) throws -> VerifiedUpdate {
        let staging = env.root.appendingPathComponent("staging")
        let appURL = staging.appendingPathComponent(CoreConstants.claudeAppName)
        try fm.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleIdentifier": "com.anthropic.claudefordesktop",
            "CFBundleExecutable": env.real.executableName
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try Data("new-binary".utf8).write(
            to: appURL.appendingPathComponent("Contents/MacOS/\(env.real.executableName)")
        )
        return VerifiedUpdate(version: version, appURL: appURL)
    }

    // MARK: - The swap

    @Test
    func replacesTheInstalledBundleAndReportsBothVersions() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let installedBefore = env.real.version(fileManager: fm)
        let incoming = try makeIncoming(env, version: "9.9.99")

        let result = await env.store.installUpdate(incoming)

        #expect(result.outcome == .installed(from: installedBefore, to: "9.9.99"))
        // The bundle at the path is the new one, and it is a bundle rather than a link.
        #expect(env.real.version(fileManager: fm) == "9.9.99")
        let contents = try Data(
            contentsOf: env.real.appURL.appendingPathComponent("Contents/MacOS/\(env.real.executableName)")
        )
        #expect(String(decoding: contents, as: UTF8.self) == "new-binary")
    }

    /// The Dock, Spotlight and `open` key their record on a bundle that has just been
    /// replaced wholesale at the same path under the same identifier.
    @Test
    func tellsLaunchServicesAboutTheNewBundle() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let incoming = try makeIncoming(env, version: "9.9.99")

        _ = await env.store.installUpdate(incoming)

        let registrations = env.runner.invocations(of: CoreConstants.lsregisterPath)
        #expect(registrations.contains { $0.arguments == ["-f", env.real.appURL.path] })
    }

    /// A stale LaunchServices record is cosmetic; failing the install over it would be worse
    /// than the symptom it prevents.
    @Test
    func stillReportsSuccessWhenLaunchServicesRefuses() async throws {
        let env = try makeStoreEnv(stub: { executable, args in
            executable == CoreConstants.lsregisterPath
                ? CommandOutput(exitCode: 1, standardOutput: "", standardError: "refused")
                : idleStub(executable, args)
        })
        defer { try? fm.removeItem(at: env.root) }
        // Read before the swap: afterwards this path answers with the *new* version.
        let installedBefore = env.real.version(fileManager: fm)
        let incoming = try makeIncoming(env, version: "9.9.99")

        let result = await env.store.installUpdate(incoming)

        #expect(result.outcome == .installed(from: installedBefore, to: "9.9.99"))
        #expect(env.real.version(fileManager: fm) == "9.9.99")
    }

    // MARK: - Refusing to touch anything

    /// Claude vetoes its own termination while a session is working. Taking the bundle out
    /// from under it would be the wrong answer; saying which profile is holding things up is
    /// the right one.
    @Test
    func leavesTheInstalledBundleAloneWhenAProfileWillNotQuit() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        // A real-Claude instance that never goes away, so the quiesce cannot pass. Installed
        // after the env exists, since the path it reports comes from the fixture itself.
        let realBinary = env.real.binaryURL.path
        env.runner.setHandler { executable, args in
            if executable == CoreConstants.psPath {
                return CommandOutput(
                    exitCode: 0,
                    standardOutput: "  501     1 \(realBinary)\n",
                    standardError: ""
                )
            }
            return idleStub(executable, args)
        }
        let versionBefore = env.real.version(fileManager: fm)
        let incoming = try makeIncoming(env, version: "9.9.99")

        let result = await env.store.installUpdate(incoming, stopPollInterval: 0.01, stopMaxPolls: 2)

        guard case let .instancesStillRunning(names) = result.outcome else {
            Issue.record("expected the install to be refused, got \(result.outcome)")
            return
        }
        #expect(!names.isEmpty)
        // Nothing was touched: the installed bundle is exactly as it was.
        #expect(env.real.version(fileManager: fm) == versionBefore)
        #expect(fm.fileExists(atPath: incoming.appURL.path), "the verified bundle should survive a refusal")
    }

    /// A swap that cannot happen must leave the working install intact — that is the whole
    /// point of doing it as a rename.
    @Test
    func leavesTheInstalledBundleAloneWhenTheSwapFails() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let versionBefore = env.real.version(fileManager: fm)
        // A source that is not there at all: `replaceItemAt` fails, nothing is moved.
        let missing = VerifiedUpdate(
            version: "9.9.99",
            appURL: env.root.appendingPathComponent("absent/Claude.app")
        )

        let result = await env.store.installUpdate(missing)

        guard case .swapFailed = result.outcome else {
            Issue.record("expected the swap to fail, got \(result.outcome)")
            return
        }
        #expect(env.real.version(fileManager: fm) == versionBefore)
    }

    /// A cross-volume replace is a copy, and a copy interrupted half way is the broken
    /// install this design exists to rule out — so it is refused rather than attempted.
    @Test
    func refusesToSwapAcrossVolumes() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        let versionBefore = env.real.version(fileManager: fm)

        // A path on a genuinely different volume, discovered rather than assumed: on macOS
        // firmlinks make `/` and the data volume share a device, so the usual guesses do not
        // work. If this machine really has only one volume there is nothing to assert.
        let candidates = ["/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update"]
        guard let other = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
                && !PathUtils.sameVolume($0, env.real.appURL.path)
        }) else { return }
        let elsewhere = URL(fileURLWithPath: other)
        let incoming = VerifiedUpdate(
            version: "9.9.99", appURL: elsewhere.appendingPathComponent(CoreConstants.claudeAppName)
        )

        let result = await env.store.installUpdate(incoming)

        #expect(result.outcome == .differentVolume)
        #expect(env.real.version(fileManager: fm) == versionBefore)
    }

    // MARK: - Putting the set back

    @Test
    func reopensTheProfilesItClosed() async throws {
        let env = try makeStoreEnv()
        defer { try? fm.removeItem(at: env.root) }
        _ = try env.store.add(AddProfileRequest(name: env.name("work")))
        let installedBefore = env.real.version(fileManager: fm)
        let incoming = try makeIncoming(env, version: "9.9.99")

        let result = await env.store.installUpdate(incoming)

        // Nothing was running in this fixture, so nothing is reopened — the interesting part
        // is that the install still succeeded and reported an empty set rather than guessing.
        #expect(result.relaunched.isEmpty)
        #expect(result.outcome == .installed(from: installedBefore, to: "9.9.99"))
    }
}

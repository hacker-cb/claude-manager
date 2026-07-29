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

    /// A keychain that refuses everything, so a real `config.json` can go through the real provider
    /// with the token arm guaranteed to fail and nothing decrypted.
    private struct RefusingKeychain: KeychainReading {
        func accounts(service _: String) throws -> [String] {
            ["Claude"]
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            throw KeychainError.interactionNotAllowed
        }
    }

    /// Real `config.json` files still yield their account hint, through the real provider, with the
    /// token deliberately unreadable.
    ///
    /// A drift guard rather than a unit test: `lastKnownAccountUuid` lives in a file Anthropic owns
    /// and can reshape, and this is what would notice — the fixtures elsewhere are ones we wrote.
    /// It is exactly the failure the hint exists for (`.keychainUnavailable`), asserted against
    /// files nobody in this repo authored.
    ///
    /// Strictly read-only and offline. Each config is **copied** to a temp dir before the provider
    /// sees it, the keychain stub refuses every read so nothing is ever decrypted, and no network
    /// client or history store is constructed. Skips cleanly on a machine with no launcher profiles.
    ///
    /// It does **not** check the hint against the uuid `/oauth/profile` returned — that needs the
    /// real key and a real decrypt, which this suite will not do. That agreement was verified by
    /// hand while designing this (5 profiles, 4 readable, all matching) and is recorded in
    /// docs/ARCHITECTURE.md.
    @Test(.enabled(if: LiveIntegrationTests.live))
    func realConfigsStillYieldTheirAccountHintWhenTheTokenCannotBeRead() async throws {
        let fm = FileManager.default
        let profiles = MetadataStore.defaultDirectory().appendingPathComponent("Profiles")
        guard let dirs = try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)
        else { return }

        let temp = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: temp) }
        let provider = DesktopSafeStorageProvider(keyStore: SafeStorageKeyStore(keychain: RefusingKeychain()))

        for (index, dir) in dirs.enumerated() {
            let source = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: source),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hint = root[CoreConstants.desktopAccountHintKey] as? String
            else { continue }
            // Desktop's own value has to be uuid-shaped, or the provider is right to drop it and
            // this profile could never be named — which is the thing that would have changed.
            #expect(hint.count == 36, "hint is not uuid-shaped in \(dir.lastPathComponent)")

            let copy = temp.appendingPathComponent("config-\(index).json")
            try data.write(to: copy)
            let reading = await provider.read(
                TokenBinding(id: "live-\(index)", configURL: copy),
                interactive: false
            )
            #expect(reading.token == .failure(.keychainUnavailable(.interactionNotAllowed)))
            #expect(reading.hintedAccountUUID == hint, "hint lost in \(dir.lastPathComponent)")
        }
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

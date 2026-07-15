import Foundation
import Testing
@testable import ClaudeManagerCore

struct ManagedConfigWriterTests {
    let fm = FileManager.default

    /// A user-data dir under a throwaway temp root, plus its expected `-3p` tier.
    struct Scene {
        let root: URL
        let userDataPath: String
        var configLibrary: URL {
            ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
        }

        var metaURL: URL {
            configLibrary.appendingPathComponent("_meta.json")
        }

        var tier: URL {
            ManagedConfigWriter.localTierURL(forUserDataPath: userDataPath)
        }
    }

    func makeScene() throws -> Scene {
        let root = try Fixture.makeTempDir()
        return Scene(root: root, userDataPath: root.appendingPathComponent("work").path)
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Path derivation

    @Test
    func configLibraryURLIsMinus3pSibling() {
        let url = ManagedConfigWriter.configLibraryURL(forUserDataPath: "/a/b/work")
        #expect(url.path == "/a/b/work-3p/configLibrary")
        // A trailing slash is trimmed so the suffix lands on the dir name.
        let trailing = ManagedConfigWriter.configLibraryURL(forUserDataPath: "/a/b/work/")
        #expect(trailing.path == "/a/b/work-3p/configLibrary")
    }

    // MARK: - Fresh write

    @Test
    func reconcileMintsMetaAndFlatConfig() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )

        let outcome = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)

        let appliedID: String
        switch outcome {
        case let .reconciled(configLibrary, id):
            #expect(configLibrary == scene.configLibrary)
            appliedID = id
        case .skippedMDMPresent:
            Issue.record("expected reconciled, got skippedMDMPresent")
            return
        }
        #expect(ManagedConfigWriter.isValidAppliedID(appliedID))

        // _meta.json points at the config file.
        let meta = try readJSON(scene.metaURL)
        #expect(meta["appliedId"] as? String == appliedID)

        // The config uses the FLAT key with a real JSON boolean.
        let configURL = scene.configLibrary.appendingPathComponent("\(appliedID).json")
        let config = try readJSON(configURL)
        #expect(config["disableAutoUpdates"] as? Bool == true)
        // Nested shape must NOT be produced.
        #expect(config["autoUpdate"] == nil)
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        #expect(raw.contains("\"disableAutoUpdates\" : true"))
    }

    // MARK: - Merge-not-clobber

    @Test
    func reconcileReusesExistingAppliedIDAndPreservesKeys() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try fm.createDirectory(at: scene.configLibrary, withIntermediateDirectories: true)
        let existingID = "550e8400-e29b-41d4-a716-446655440000"
        try Data("{\"appliedId\":\"\(existingID)\"}".utf8).write(to: scene.metaURL)
        let configURL = scene.configLibrary.appendingPathComponent("\(existingID).json")
        try Data("{\"someOtherKey\":123,\"telemetryDisabled\":true}".utf8).write(to: configURL)

        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )
        let outcome = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)

        #expect(outcome == .reconciled(configLibrary: scene.configLibrary, appliedID: existingID))
        let config = try readJSON(configURL)
        // Our key added; foreign keys preserved untouched.
        #expect(config["disableAutoUpdates"] as? Bool == true)
        #expect(config["someOtherKey"] as? Int == 123)
        #expect(config["telemetryDisabled"] as? Bool == true)
    }

    @Test
    func reconcileReplacesMalformedMeta() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try fm.createDirectory(at: scene.configLibrary, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: scene.metaURL)

        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )
        let outcome = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)

        // A fresh valid id is minted and a well-formed config written.
        guard case let .reconciled(_, appliedID) = outcome else {
            Issue.record("expected reconciled")
            return
        }
        #expect(ManagedConfigWriter.isValidAppliedID(appliedID))
        let meta = try readJSON(scene.metaURL)
        #expect(meta["appliedId"] as? String == appliedID)
    }

    @Test
    func mintingPreservesMetaSiblingKeys() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        try fm.createDirectory(at: scene.configLibrary, withIntermediateDirectories: true)
        // Invalid appliedId forces a re-mint; a sibling key must survive it.
        try Data("{\"appliedId\":\"not-valid\",\"schemaVersion\":7}".utf8).write(to: scene.metaURL)

        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )
        guard case let .reconciled(_, appliedID) = try writer.reconcile(
            .clone(), userDataPath: scene.userDataPath
        ) else { Issue.record("expected reconciled"); return }

        let meta = try readJSON(scene.metaURL)
        #expect(ManagedConfigWriter.isValidAppliedID(appliedID))
        #expect(meta["appliedId"] as? String == appliedID)
        #expect(meta["schemaVersion"] as? Int == 7)
    }

    // MARK: - Idempotence

    @Test
    func reconcileIsIdempotent() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )

        let first = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)
        guard case let .reconciled(_, id1) = first else { Issue.record("expected reconciled"); return }
        let configURL = scene.configLibrary.appendingPathComponent("\(id1).json")
        let bytes1 = try Data(contentsOf: configURL)

        let second = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)
        guard case let .reconciled(_, id2) = second else { Issue.record("expected reconciled"); return }
        let bytes2 = try Data(contentsOf: configURL)

        #expect(id1 == id2)
        #expect(bytes1 == bytes2)
    }

    // MARK: - Toggling off

    @Test
    func reconcileTogglingOffDropsManagedKeyKeepsForeign() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )

        guard case let .reconciled(_, appliedID) = try writer.reconcile(
            .clone(),
            userDataPath: scene.userDataPath
        )
        else { Issue.record("expected reconciled"); return }
        let configURL = scene.configLibrary.appendingPathComponent("\(appliedID).json")
        // Inject a foreign key that must survive the toggle-off.
        var seeded = try readJSON(configURL)
        seeded["foreignKey"] = "keep"
        try JSONSerialization.data(withJSONObject: seeded).write(to: configURL)

        _ = try writer.reconcile(
            ProfileManagedConfig(disableAutoUpdates: false),
            userDataPath: scene.userDataPath
        )
        let config = try readJSON(configURL)
        #expect(config["disableAutoUpdates"] == nil)
        #expect(config["foreignKey"] as? String == "keep")
    }

    // MARK: - MDM guard

    @Test
    func mdmPresentSkipsAndWritesNothing() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let mdm = scene.root.appendingPathComponent("managed.plist")
        try Data("<plist/>".utf8).write(to: mdm)
        let writer = ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: [mdm])

        #expect(writer.mdmPresent)
        let outcome = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)
        #expect(outcome == .skippedMDMPresent)
        // The local tier is never created.
        #expect(!fm.fileExists(atPath: scene.tier.path))
    }

    @Test
    func mdmDetectedForAnyBundleIDPlist() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let absent = scene.root.appendingPathComponent("current.plist")
        let legacy = scene.root.appendingPathComponent("legacy.plist")
        try Data("<plist/>".utf8).write(to: legacy)
        // Current-id plist absent, legacy-id plist present → still detected as MDM.
        let writer = ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: [absent, legacy])
        #expect(writer.mdmPresent)
        #expect(writer.presentManagedPreferencesURL == legacy)
    }

    // MARK: - Removal

    @Test
    func removeOverlayDeletesTier() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )
        _ = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)
        #expect(fm.fileExists(atPath: scene.tier.path))

        try writer.removeOverlay(userDataPath: scene.userDataPath)
        #expect(!fm.fileExists(atPath: scene.tier.path))
        // Idempotent: removing an absent tier is a silent no-op.
        try writer.removeOverlay(userDataPath: scene.userDataPath)
    }

    // MARK: - isSatisfied

    @Test
    func isSatisfiedTracksOverlayState() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let writer = ManagedConfigWriter(
            fileManager: fm,
            managedPreferencesURLs: [scene.root.appendingPathComponent("absent.plist")]
        )
        #expect(!writer.isSatisfied(.clone(), userDataPath: scene.userDataPath))
        _ = try writer.reconcile(.clone(), userDataPath: scene.userDataPath)
        #expect(writer.isSatisfied(.clone(), userDataPath: scene.userDataPath))
    }

    @Test
    func isSatisfiedWhenMDMPresent() throws {
        let scene = try makeScene()
        defer { try? fm.removeItem(at: scene.root) }
        let mdm = scene.root.appendingPathComponent("managed.plist")
        try Data("<plist/>".utf8).write(to: mdm)
        let writer = ManagedConfigWriter(fileManager: fm, managedPreferencesURLs: [mdm])
        // MDM is expected to own the policy, so a missing local overlay still "satisfies".
        #expect(writer.isSatisfied(.clone(), userDataPath: scene.userDataPath))
    }

    // MARK: - appliedId validation

    @Test
    func appliedIDValidation() {
        #expect(ManagedConfigWriter.isValidAppliedID("550e8400-e29b-41d4-a716-446655440000"))
        #expect(!ManagedConfigWriter.isValidAppliedID("550E8400-E29B-41D4-A716-446655440000")) // uppercase
        #expect(!ManagedConfigWriter.isValidAppliedID("too-short"))
        #expect(!ManagedConfigWriter.isValidAppliedID("550e8400e29b41d4a716446655440000zz")) // 34 + non-hex
        #expect(ManagedConfigWriter.isValidAppliedID(UUID().uuidString.lowercased()))
    }
}

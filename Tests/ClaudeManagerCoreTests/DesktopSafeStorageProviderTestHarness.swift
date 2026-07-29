import Foundation
import Testing
@testable import ClaudeManagerCore

/// Shared stubs and builders for `DesktopSafeStorageProviderTests`. In an extension (and its own
/// file) so the suite body stays about the behaviour under test rather than its scaffolding —
/// the same split `UsageServiceTestHarness` makes.
extension DesktopSafeStorageProviderTests {
    // MARK: - Keychains

    /// Stub keychain: one account under the service, returning a fixed secret or a chosen
    /// `KeychainError`. Enumeration always finds the account (the item exists); the read is what
    /// succeeds or fails — mirroring a present item whose data ACL blocks a background read.
    struct StubKeychain: KeychainReading {
        let result: Result<Data, KeychainError>
        func accounts(service _: String) throws -> [String] {
            ["Claude"]
        }

        func secret(service _: String, account _: String, interactive _: Bool) throws -> Data {
            try result.get()
        }
    }

    /// Stub keychain with a per-account result. `accounts` reports exactly the keys present (an
    /// empty map → no item under the service), and a read of an absent account throws `.notFound`
    /// — so a test can model a machine that stores the password under any one account name, both,
    /// or a name no static list would contain.
    struct PerAccountKeychain: KeychainReading {
        let byAccount: [String: Result<Data, KeychainError>]
        func accounts(service _: String) throws -> [String] {
            Array(byAccount.keys)
        }

        func secret(service _: String, account: String, interactive _: Bool) throws -> Data {
            try (byAccount[account] ?? .failure(.notFound)).get()
        }
    }

    /// Answers differently by the `interactive` flag and records which accounts were read
    /// interactively — modelling an item locked to a background read but readable once authorized,
    /// so a test can assert how many Always-Allow dialogs a resolution would raise.
    final class InteractiveRecordingKeychain: KeychainReading, @unchecked Sendable {
        typealias Answer = (background: Result<Data, KeychainError>, interactive: Result<Data, KeychainError>)
        private let table: [String: Answer]
        private let lock = NSLock()
        private var interactiveReadsStore: [String] = []
        init(_ table: [String: Answer]) {
            self.table = table
        }

        var interactiveReads: [String] {
            lock.withLock { interactiveReadsStore }
        }

        func accounts(service _: String) throws -> [String] {
            Array(table.keys)
        }

        func secret(service _: String, account: String, interactive: Bool) throws -> Data {
            if interactive { lock.withLock { interactiveReadsStore.append(account) } }
            guard let entry = table[account] else { throw KeychainError.notFound }
            return try (interactive ? entry.interactive : entry.background).get()
        }
    }

    // MARK: - Builders

    func inferenceCompositeKey() -> String {
        "\(clientID):\(org):https://api.anthropic.com:user:inference user:file_upload user:profile"
    }

    func profileCompositeKey() -> String {
        "\(clientID):\(org):https://api.anthropic.com:user:profile"
    }

    /// Write a `config.json` whose token-cache key is the given map, encrypted under the key
    /// derived from `password` (the same the stub keychain returns) — a faithful blob with no real
    /// token. `key` defaults to the current `tokenCacheV2`; pass the v1 name to exercise the
    /// legacy fallback, and `name` to place the file somewhere other than `config.json`.
    func writeConfig(
        cache: [String: Any],
        into dir: URL,
        key cacheKey: String = CoreConstants.desktopTokenCacheKeyV2,
        name: String = "config.json"
    ) throws -> URL {
        let key = SafeStorageDecryptor.deriveKey(password: password)!
        let cacheData = try JSONSerialization.data(withJSONObject: cache)
        let blob = SafeStorageDecryptorTests.makeV10Blob(cacheData, key: key)
        let root: [String: Any] = [cacheKey: blob.base64EncodedString()]
        let url = dir.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    /// Write a `config.json` carrying **both** cache keys, encrypted separately. The shape that
    /// decides whether an empty elected cache may claim `.signedOut`: the election takes v2 over v1
    /// by presence, so a populated sibling must hold it back.
    func writeConfig(
        v2: [String: Any],
        v1: [String: Any],
        into dir: URL,
        name: String = "config.json"
    ) throws -> URL {
        let key = SafeStorageDecryptor.deriveKey(password: password)!
        let v2Blob = try SafeStorageDecryptorTests
            .makeV10Blob(JSONSerialization.data(withJSONObject: v2), key: key)
        let v1Blob = try SafeStorageDecryptorTests
            .makeV10Blob(JSONSerialization.data(withJSONObject: v1), key: key)
        let root: [String: Any] = [
            CoreConstants.desktopTokenCacheKeyV2: v2Blob.base64EncodedString(),
            CoreConstants.desktopTokenCacheKeyV1: v1Blob.base64EncodedString()
        ]
        let url = dir.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    /// Write a `config.json` whose v2 key holds an arbitrary raw string — typically one that is not
    /// base64 at all — beside a properly encrypted v1. The shape that decides whether election
    /// falls through to a decodable sibling.
    func writeConfig(rawV2: String, v1: [String: Any], into dir: URL) throws -> URL {
        let key = SafeStorageDecryptor.deriveKey(password: password)!
        let blob = try SafeStorageDecryptorTests
            .makeV10Blob(JSONSerialization.data(withJSONObject: v1), key: key)
        let root: [String: Any] = [
            CoreConstants.desktopTokenCacheKeyV2: rawV2,
            CoreConstants.desktopTokenCacheKeyV1: blob.base64EncodedString()
        ]
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    func provider(keychain: KeychainReading) -> DesktopSafeStorageProvider {
        DesktopSafeStorageProvider(keyStore: SafeStorageKeyStore(keychain: keychain))
    }

    func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}

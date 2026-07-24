import Foundation

/// Owns the derived Electron safeStorage AES key and caches it for the process lifetime, so
/// the usage poller reads the keychain **once** (one "Always Allow" prompt) rather than on
/// every tick. An `actor` because the cache is mutable shared state touched from the poll
/// loop and on-demand refreshes.
///
/// The `interactive` flag threads through to the keychain read: a background poll passes
/// `false` (fail fast on a locked / not-yet-authorized item), an explicit user gesture
/// passes `true` (allow the one-time dialog). Once the key is cached, neither path touches
/// the keychain again.
public actor SafeStorageKeyStore {
    private let keychain: KeychainReading
    private var cachedKey: Data?

    public init(keychain: KeychainReading = SecItemKeychainReader()) {
        self.keychain = keychain
    }

    /// The 16-byte AES key, deriving (and caching) it on first use. Throws `KeychainError`
    /// when the secret can't be read; `SafeStorageError.decryptFailed` if derivation fails
    /// (effectively never for a valid password).
    public func derivedKey(interactive: Bool = false) throws -> Data {
        if let cachedKey { return cachedKey }
        let password = try keychain.secret(
            service: CoreConstants.safeStorageKeychainService,
            account: CoreConstants.safeStorageKeychainAccount,
            interactive: interactive
        )
        guard let key = SafeStorageDecryptor.deriveKey(password: password) else {
            throw SafeStorageError.decryptFailed
        }
        cachedKey = key
        return key
    }

    /// Whether the key is already cached (no keychain access needed). Lets the UI know it
    /// can render usage without prompting.
    public var isUnlocked: Bool {
        cachedKey != nil
    }

    /// Drop the cached key — e.g. after an access error, to force a fresh (possibly
    /// interactive) read on the next attempt.
    public func invalidate() {
        cachedKey = nil
    }
}

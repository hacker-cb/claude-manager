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

    /// The 16-byte AES key for the fleet, cached after the first successful resolution.
    ///
    /// A cached key is returned **as-is** — the whole fleet shares one, so a single binding's
    /// corrupt blob must not re-resolve it (that's a decrypt failure for *that* binding, handled by
    /// the caller), and a genuine key rotation is caught fleet-wide by `UsageService` invalidating
    /// this cache when *every* binding fails.
    ///
    /// Resolution (no cache yet) is where `accepts` earns its keep: the keychain **account** that
    /// holds the password differs across Claude Desktop versions
    /// (`CoreConstants.safeStorageKeychainAccounts`), and a machine can carry a stale one beside the
    /// live one, so the right key is the one that actually *decrypts* — not a fixed account. Each
    /// candidate is tried in turn and the first whose derived key satisfies `accepts` (the caller's
    /// decrypt probe) is cached. A candidate whose item is absent costs no prompt, so the common
    /// single-account machine still prompts exactly once.
    ///
    /// Throws the last `KeychainError` when no candidate's secret could be read at all
    /// (→ keychain-unavailable), or `SafeStorageError.decryptFailed` when a secret *was* read but
    /// no candidate key decrypted (→ a wrong / rotated key, or this binding's blob is corrupt).
    public func key(interactive: Bool = false, accepts: @Sendable (Data) -> Bool) throws -> Data {
        if let cachedKey { return cachedKey }
        var keychainError: KeychainError?
        for account in CoreConstants.safeStorageKeychainAccounts {
            let derived: Data
            do {
                let password = try keychain.secret(
                    service: CoreConstants.safeStorageKeychainService,
                    account: account,
                    interactive: interactive
                )
                guard let key = SafeStorageDecryptor.deriveKey(password: password) else { continue }
                derived = key
            } catch let error as KeychainError {
                keychainError = error
                continue
            }
            if accepts(derived) {
                cachedKey = derived
                return derived
            }
        }
        if let keychainError { throw keychainError }
        throw SafeStorageError.decryptFailed
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

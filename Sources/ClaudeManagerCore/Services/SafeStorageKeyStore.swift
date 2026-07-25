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
    /// Resolution (no cache yet) is where `accepts` earns its keep. The keychain **account** that
    /// holds the password is version-dependent (`"Claude"` from the sync provider, `"Claude Key"`
    /// from the async one — see `CoreConstants.safeStorageKeychainService`), and a machine can
    /// carry a stale one beside the live one, so nothing is hard-coded: we enumerate every account
    /// under the stable service (attributes only → no prompt) and read each in turn, caching the
    /// first whose derived key satisfies `accepts` (the caller's decrypt probe). Since the accounts
    /// normally share one password, the first read decrypts and the common machine prompts exactly
    /// once. Sorted for a stable which-prompts-first order across runs.
    ///
    /// Throws `KeychainError.notFound` when no item exists under the service at all, the last
    /// `KeychainError` when items exist but none could be read (→ keychain-unavailable), or
    /// `SafeStorageError.decryptFailed` when a secret *was* read but no key decrypted (→ a wrong /
    /// rotated key, or this binding's blob is corrupt).
    public func key(interactive: Bool = false, accepts: @Sendable (Data) -> Bool) throws -> Data {
        if let cachedKey { return cachedKey }
        let service = CoreConstants.safeStorageKeychainService
        let accounts = try keychain.accounts(service: service).sorted()
        guard !accounts.isEmpty else { throw KeychainError.notFound }
        var keychainError: KeychainError?
        for account in accounts {
            let derived: Data
            do {
                let password = try keychain.secret(
                    service: service,
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

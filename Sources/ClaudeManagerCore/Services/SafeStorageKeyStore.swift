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
    /// under the stable service (attributes only → no prompt) and keep the first whose derived key
    /// satisfies `accepts` (the caller's decrypt probe). Accounts are sorted for a stable order.
    ///
    /// Reading is **two-pass** to keep prompts minimal. Pass 1 reads every account non-interactively
    /// (never prompts): an already-authorized account — including a stale one — is tested here, so if
    /// the live account is authorized the whole thing resolves with zero prompts, and a stale
    /// authorized account is rejected without ever prompting. Only accounts that are genuinely locked
    /// (returned `.interactionNotAllowed`) are retried in pass 2, and only when the caller passed
    /// `interactive: true`. So the common machine prompts at most once; a stale item can add a prompt
    /// only when *it too* is unauthorized, never merely by existing.
    ///
    /// Throws `KeychainError.notFound` when no item exists under the service at all; a
    /// `KeychainError` (preferring the actionable `.interactionNotAllowed`) when items exist but
    /// **none** could be read; or `SafeStorageError.decryptFailed` when at least one secret *was*
    /// read yet no derived key decrypted. Reading a secret proves the keychain is available, so
    /// that last case must not surface a sibling account's `.interactionNotAllowed` — authorizing
    /// can't fix a key we already hold that simply doesn't decrypt this blob (rotated key / corrupt
    /// cache); it's a login-needed/decrypt failure, and mislabelling it sends the user chasing a
    /// prompt that changes nothing.
    public func key(interactive: Bool = false, accepts: @Sendable (Data) -> Bool) throws -> Data {
        if let cachedKey { return cachedKey }
        let service = CoreConstants.safeStorageKeychainService
        let accounts = try keychain.accounts(service: service).sorted()
        guard !accounts.isEmpty else { throw KeychainError.notFound }

        var keychainError: KeychainError?
        var readAnySecret = false
        var deferredToInteractive: [String] = []

        /// Read one account and test its derived key against the probe. Returns the accepted key, or
        /// nil to keep looking — deferring an unauthorized item for a later interactive retry, and
        /// recording any other read error (preferring the actionable `.interactionNotAllowed`).
        func resolve(_ account: String, interactive: Bool) -> Data? {
            let password: Data
            do {
                password = try keychain.secret(service: service, account: account, interactive: interactive)
            } catch KeychainError.interactionNotAllowed {
                deferredToInteractive.append(account)
                return nil
            } catch let error as KeychainError {
                if keychainError != .interactionNotAllowed { keychainError = error }
                return nil
            } catch {
                return nil
            }
            readAnySecret = true
            guard let derived = SafeStorageDecryptor.deriveKey(password: password) else { return nil }
            return accepts(derived) ? derived : nil
        }

        // Pass 1 — prompt-free (`interactive: false`): resolve outright if any *readable* account
        // decrypts. A stale-but-readable account is tested and rejected here, so it never triggers
        // a prompt below — the second Always-Allow dialog on a dual-item machine is thus avoided.
        for account in accounts {
            if let key = resolve(account, interactive: false) { cachedKey = key; return key }
        }
        // Pass 2 — only with the caller's blessing, and only for accounts that genuinely need a
        // prompt (unreadable in pass 1). `for-in` captures the array by value, so a read re-denied
        // here (which re-defers the account) doesn't get revisited in this same loop.
        if interactive {
            for account in deferredToInteractive {
                if let key = resolve(account, interactive: true) { cachedKey = key; return key }
            }
        }

        // A key we could read but none decrypted → decrypt failure, not keychain-unavailable.
        if readAnySecret { throw SafeStorageError.decryptFailed }
        if !deferredToInteractive.isEmpty { throw KeychainError.interactionNotAllowed }
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

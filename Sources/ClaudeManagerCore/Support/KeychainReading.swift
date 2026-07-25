import Foundation
import LocalAuthentication
import Security

/// Why a keychain read couldn't return a secret. `interactionNotAllowed` is the *expected*
/// background-path outcome when the app isn't yet in the item's ACL (or the keychain is
/// locked) — the caller serves stale and defers the real prompt to a foreground gesture.
public enum KeychainError: Error, Equatable, Sendable {
    /// No such generic-password item under the service — genuinely absent (`errSecItemNotFound`).
    /// Distinct from an access/auth failure: the UI tells the user to sign in for this one, so an
    /// item that *exists* but couldn't be read must not land here.
    case notFound
    /// A prompt would be required but UI was suppressed (`kSecUseAuthenticationUISkip`) —
    /// or the keychain is locked. Non-fatal: retry interactively on a user gesture.
    case interactionNotAllowed
    /// Any other `OSStatus` from `SecItemCopyMatching`, including an auth failure
    /// (`errSecAuthFailed`) — an existing item we couldn't read, which is *not* a missing item.
    case unexpected(OSStatus)
}

/// Reads a generic-password secret from the login keychain. Behind a protocol so the token
/// provider can be tested with a stub — production has no "Claude Safe Storage" item on CI,
/// and tests must never touch the real one.
public protocol KeychainReading: Sendable {
    /// Every generic-password **account** present under `service`, attributes only. Returns the
    /// data ACL untouched (`kSecReturnData: false`), so it never prompts and never unlocks — a
    /// cheap way to discover which account name a given machine stores the password under without
    /// hard-coding the version-dependent set. An empty array means no such item exists.
    func accounts(service: String) throws -> [String]

    /// Read the secret bytes for `(service, account)`. When `interactive` is false the read
    /// uses `kSecUseAuthenticationUISkip`, so a not-yet-authorized item (or locked keychain)
    /// fails fast with `.interactionNotAllowed` instead of blocking a background poll on a
    /// modal prompt. Pass `interactive: true` from an explicit user gesture to allow the
    /// one-time "Always Allow" dialog.
    func secret(service: String, account: String, interactive: Bool) throws -> Data
}

/// The real reader: `SecItemCopyMatching` against the login keychain.
public struct SecItemKeychainReader: KeychainReading {
    public init() {}

    public func accounts(service: String) throws -> [String] {
        // Fail fast rather than prompt or hide. On a locked login keychain (SSH session, manual
        // lock) the enumeration must not pop an unlock dialog mid-poll and — crucially under
        // `kSecMatchLimitAll` — must not *silently omit* auth-required items (which the deprecated
        // `kSecUseAuthenticationUISkip` does, leaving an empty set that reads as `.notFound`). An
        // `LAContext` with `interactionNotAllowed` makes the whole call fail with
        // `errSecInteractionNotAllowed` instead → `.interactionNotAllowed` (serve stale, retry
        // interactively). This is the non-deprecated form of `kSecUseAuthenticationUIFail`.
        let noninteractive = LAContext()
        noninteractive.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Attributes only — never the data — so an unlocked keychain consults no item's ACL and
            // doesn't prompt (verified against the real dual-account item).
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: noninteractive,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unexpected(status)
        }
    }

    public func secret(service: String, account: String, interactive: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // Suppress the auth UI on the background path so a locked / not-yet-authorized
        // item returns immediately (→ serve stale) rather than popping a prompt mid-poll.
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.notFound }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        // `errSecAuthFailed` is an *existing* item we couldn't read (denied / auth failed), not a
        // missing one — it falls to `default` → `.unexpected`, so the UI shows a keychain error
        // rather than telling the user to sign in for an item that is actually there.
        default:
            throw KeychainError.unexpected(status)
        }
    }
}

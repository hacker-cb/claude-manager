import Foundation
import Security

/// Why a keychain read couldn't return a secret. `interactionNotAllowed` is the *expected*
/// background-path outcome when the app isn't yet in the item's ACL (or the keychain is
/// locked) — the caller serves stale and defers the real prompt to a foreground gesture.
public enum KeychainError: Error, Equatable, Sendable {
    /// No such item, or access denied outright.
    case notFound
    /// A prompt would be required but UI was suppressed (`kSecUseAuthenticationUISkip`) —
    /// or the keychain is locked. Non-fatal: retry interactively on a user gesture.
    case interactionNotAllowed
    /// Any other `OSStatus` from `SecItemCopyMatching`.
    case unexpected(OSStatus)
}

/// Reads a generic-password secret from the login keychain. Behind a protocol so the token
/// provider can be tested with a stub — production has no "Claude Safe Storage" item on CI,
/// and tests must never touch the real one.
public protocol KeychainReading: Sendable {
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
        case errSecItemNotFound, errSecAuthFailed:
            throw KeychainError.notFound
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unexpected(status)
        }
    }
}

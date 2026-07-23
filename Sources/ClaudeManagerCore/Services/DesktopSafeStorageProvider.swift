import Foundation

/// The primary token provider: reads a Desktop account's `config.json`, decrypts its
/// `oauth:tokenCacheV2` with the shared safeStorage key, and returns the bearer token.
///
/// Covers every account signed in on the Desktop side — including one (like `ps@`) that has
/// no CLI login and is unreachable via CLI keychain creds. The key is read once and cached
/// by `SafeStorageKeyStore`, so a fleet of bindings costs a single keychain access.
public struct DesktopSafeStorageProvider: TokenProvider {
    private let keyStore: SafeStorageKeyStore
    private let decryptor: SafeStorageDecryptor

    public init(
        keyStore: SafeStorageKeyStore,
        decryptor: SafeStorageDecryptor = SafeStorageDecryptor()
    ) {
        self.keyStore = keyStore
        self.decryptor = decryptor
    }

    public func token(
        for binding: TokenBinding,
        interactive: Bool
    ) async -> Result<DesktopToken, TokenProviderError> {
        guard let configData = try? Data(contentsOf: binding.configURL),
              let root = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]
        else {
            return .failure(.configUnreadable)
        }

        let cacheString = (root[CoreConstants.desktopTokenCacheKeyV2] as? String)
            ?? (root[CoreConstants.desktopTokenCacheKeyV1] as? String)
        guard let cacheString, let blob = Data(base64Encoded: cacheString) else {
            return .failure(.noTokenCache)
        }

        let key: Data
        do {
            key = try await keyStore.derivedKey(interactive: interactive)
        } catch let error as KeychainError {
            return .failure(.keychainUnavailable(error))
        } catch let error as SafeStorageError {
            return .failure(.decryptFailed(error))
        } catch {
            return .failure(.malformedCache)
        }

        // No side effects on failure here: the key store is shared across the whole fleet,
        // so invalidating it because *one* binding's blob won't decrypt would drop a key that
        // decrypts every other account fine (causing repeated keychain prompts). Rotated-key
        // self-heal is handled fleet-wide by UsageService — invalidate once only when *every*
        // binding fails to decrypt — where the whole-fleet view can tell rotation from a single
        // corrupt blob.
        let plaintext: Data
        switch decryptor.decrypt(v10Blob: blob, key: key) {
        case let .success(data): plaintext = data
        case let .failure(error): return .failure(.decryptFailed(error))
        }

        guard let cache = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else {
            return .failure(.malformedCache)
        }

        guard let (compositeKey, value) = pickEntry(from: cache) else {
            return .failure(.noUsableEntry)
        }
        guard let token = value["token"] as? String, !token.isEmpty else {
            return .failure(.noUsableEntry)
        }

        return .success(DesktopToken(
            token: token,
            expiresAt: expiry(from: value["expiresAt"]),
            scopes: scopes(fromComposite: compositeKey),
            organizationUUID: organizationUUID(fromComposite: compositeKey),
            subscriptionType: value["subscriptionType"] as? String,
            rateLimitTier: value["rateLimitTier"] as? String,
            bindingID: binding.id,
            lastKnownAccountUUID: root[CoreConstants.desktopLastAccountKey] as? String
        ))
    }

    // MARK: - tokenCacheV2 map interpretation

    /// Pick the entry to use: the Claude Code client with the inference scope (the boot
    /// token), else any entry carrying the profile scope. The composite key's audience
    /// (`https://api.anthropic.com`) contains colons, so it is matched by substring, never
    /// split on `:`.
    private func pickEntry(from cache: [String: Any]) -> (String, [String: Any])? {
        let entries: [(String, [String: Any])] = cache.compactMap { key, value in
            guard let dict = value as? [String: Any] else { return nil }
            return (key, dict)
        }
        let inference = entries.first {
            $0.0.hasPrefix(CoreConstants.oauthClientID) && $0.0.contains(CoreConstants.oauthInferenceScope)
        }
        let profile = entries.first { $0.0.contains(CoreConstants.oauthProfileScope) }
        return inference ?? profile
    }

    /// `expiresAt` is epoch **milliseconds**. A missing/odd value → `.distantFuture` so the
    /// poller still attempts the call; a genuinely dead token then fails 401 (terminal).
    private func expiry(from any: Any?) -> Date {
        let millis: Double? = if let number = any as? NSNumber {
            number.doubleValue
        } else if let double = any as? Double {
            double
        } else {
            nil
        }
        guard let millis else { return .distantFuture }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// Scopes are the space-separated tail after the audience in the composite key. Matched
    /// on the host (`anthropic.com:`) so it doesn't depend on the scheme.
    private func scopes(fromComposite key: String) -> [String] {
        if let range = key.range(of: "anthropic.com:") {
            return key[range.upperBound...].split(separator: " ").map(String.init)
        }
        // Fallback if the audience shape ever changes: the first scope may be fused onto the
        // audience segment (`…:user:inference`), so a `hasPrefix("user:")` split would drop
        // it. Match the scopes we actually gate on by substring, which can't lose them.
        return [CoreConstants.oauthInferenceScope, CoreConstants.oauthProfileScope]
            .filter(key.contains)
    }

    /// The organization UUID is the 36 chars immediately after `"<clientID>:"`.
    private func organizationUUID(fromComposite key: String) -> String? {
        let prefix = "\(CoreConstants.oauthClientID):"
        guard key.hasPrefix(prefix) else { return nil }
        let uuid = String(key.dropFirst(prefix.count).prefix(36))
        return uuid.count == 36 ? uuid : nil
    }
}

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

    /// Scratch state threaded through `SafeStorageKeyStore.key`'s `accepts` probe: the plaintext the
    /// accepted candidate produced (so the caller decrypts the blob once, not twice) and the most
    /// recent rejection reason (so a not-v10 / corrupt blob is reported precisely, not as a generic
    /// wrong-key `decryptFailed`). `@unchecked Sendable` because the probe closure is `@Sendable`,
    /// but it runs synchronously inside the actor before `key` returns — no concurrent access.
    private final class ProbeResult: @unchecked Sendable {
        var plaintext: Data?
        var lastFailure: TokenProviderError = .decryptFailed(.decryptFailed)
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

        // Both cache keys, v2 first — and **every** decodable one is kept, not just the first.
        // Neither presence nor decodability can tell which of them holds the live token: an
        // upgraded profile can carry a corrupt v2 beside a live v1, or an emptied v2 beside a v1
        // that still has the entries. Deciding on either alone buried a usable token in the same
        // file we had already read.
        let present = [
            root[CoreConstants.desktopTokenCacheKeyV2] as? String,
            root[CoreConstants.desktopTokenCacheKeyV1] as? String
        ].compactMap(\.self)
        guard !present.isEmpty else { return .failure(.noTokenCache) }
        // Present but undecodable *everywhere* is a corrupt cache, not an absent login. The two
        // used to share `.noTokenCache` harmlessly, when it meant no more than "no token here";
        // it now carries a sign-in remedy and drops the binding out of its account's fan-out, so
        // coalescing them would tell a user with a damaged config to sign in — which cannot fix
        // it — and quietly rewrite what the other profiles on that login say about themselves.
        let blobs = present.compactMap { Data(base64Encoded: $0) }
        guard let blob = blobs.first else { return .failure(.malformedCache) }

        // Resolve the safeStorage key by which keychain account's password actually decrypts this
        // blob — the account name under the service varies by Claude Desktop version (`Claude` vs
        // `Claude Key`), and a stale item can sit beside the live one, so the store enumerates them
        // and this probe picks the live one. A cached key is returned as-is; only the first
        // resolution runs the probe. The probe records the plaintext it produced (reused below so
        // the blob is decrypted once, not twice) and, on rejection, the precise reason.
        let probe = ProbeResult()
        let key: Data
        do {
            key = try await keyStore.key(interactive: interactive) { [decryptor] candidate in
                switch decryptor.decrypt(v10Blob: blob, key: candidate) {
                case let .success(plaintext):
                    // Accept only if it decrypts to a JSON *object* — the token cache's shape — not
                    // merely on PKCS7 success. A wrong key (a stale account tried before the live
                    // one) unpads cleanly ~1/256 of the time on garbage; accepting on decrypt alone
                    // would cache that garbage key and never reach the live account. Requiring valid
                    // JSON makes a false accept astronomically unlikely.
                    guard (try? JSONSerialization.jsonObject(with: plaintext)) is [String: Any] else {
                        probe.lastFailure = .malformedCache
                        return false
                    }
                    probe.plaintext = plaintext
                    return true
                case let .failure(error):
                    probe.lastFailure = .decryptFailed(error)
                    return false
                }
            }
        } catch let error as KeychainError {
            return .failure(.keychainUnavailable(error))
        } catch is SafeStorageError {
            // Every readable account's key failed the probe. Report the precise reason the probe
            // last saw (e.g. `.notV10` when the blob scheme changed, or `.malformedCache`) rather
            // than a blanket `.decryptFailed(.decryptFailed)`, so a blob-shape failure isn't misread
            // as a rotated key and doesn't trip the fleet-wide self-heal.
            return .failure(probe.lastFailure)
        } catch {
            return .failure(.malformedCache)
        }

        // Reuse the plaintext the probe already produced on a fresh resolution; only the cached-key
        // path (the probe didn't run this call) decrypts here. No side effects on failure: the
        // shared fleet key must not be invalidated for one binding's corrupt blob — rotated-key
        // self-heal is handled fleet-wide by UsageService (invalidate once only when *every* binding
        // fails), where the whole-fleet view can tell rotation from a single corrupt blob.
        let plaintext: Data
        if let captured = probe.plaintext {
            plaintext = captured
        } else {
            switch decryptor.decrypt(v10Blob: blob, key: key) {
            case let .success(data): plaintext = data
            case let .failure(error): return .failure(.decryptFailed(error))
            }
        }

        guard let first = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else {
            return .failure(.malformedCache)
        }

        // An empty map is what Desktop's logout leaves behind — it rewrites the key rather than
        // removing it. But only the *elected* blob has been read so far, and an emptied v2 can sit
        // beside a v1 that still holds the entries, so try the rest before concluding anything. The
        // key is already resolved by here, so the extra decrypt costs nothing but the call.
        let cache = first.isEmpty ? (firstNonEmptyCache(in: blobs.dropFirst(), key: key) ?? first) : first

        // Every cache this profile has is empty, which is exactly and only what signing out
        // produces — the one failure whose remedy is a sign-in. Told apart from `.noUsableEntry`
        // below, which keeps its meaning of "entries exist, none of them ours": offering "sign in"
        // for a cache full of another client's tokens sends the user to do the one thing that
        // cannot help.
        guard !cache.isEmpty else { return .failure(.signedOut) }

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
            bindingID: binding.id
        ))
    }

    /// The first of these blobs that decrypts to a **non-empty** token-cache map, or nil.
    ///
    /// Only reached when the elected cache turned out empty. A blob that won't decrypt or isn't a
    /// JSON object is skipped rather than reported: the elected one already decrypted cleanly, so
    /// the key is right and a broken sibling says nothing about this profile's login.
    private func firstNonEmptyCache(in blobs: ArraySlice<Data>, key: Data) -> [String: Any]? {
        for blob in blobs {
            guard case let .success(plaintext) = decryptor.decrypt(v10Blob: blob, key: key),
                  let cache = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
                  !cache.isEmpty
            else { continue }
            return cache
        }
        return nil
    }

    // MARK: - tokenCacheV2 map interpretation

    /// Pick the entry to use: the Claude Code client with the inference scope (the boot
    /// token), else any entry carrying the profile scope. The composite key's audience
    /// (`https://api.anthropic.com`) contains colons, so it is matched by substring, never
    /// split on `:`.
    ///
    /// More than one entry can match — a user who belongs to several organizations, or a stale
    /// entry sitting beside a fresh one — so the choice must not depend on `Dictionary` order,
    /// which Swift randomizes per process (the same cache would otherwise elect a different,
    /// possibly expired, token between launches).
    private func pickEntry(from cache: [String: Any]) -> (String, [String: Any])? {
        let entries: [(String, [String: Any])] = cache
            .compactMap { key, value in
                guard let dict = value as? [String: Any] else { return nil }
                return (key, dict)
            }
            .sorted { $0.0 < $1.0 }
        let inference = freshest(among: entries) {
            $0.hasPrefix(CoreConstants.oauthClientID) && $0.contains(CoreConstants.oauthInferenceScope)
        }
        let profile = freshest(among: entries) { $0.contains(CoreConstants.oauthProfileScope) }
        return inference ?? profile
    }

    /// The latest-expiring entry whose key matches — so a live token wins over a dead one in the
    /// same cache. `max(by:)` keeps the first of equal elements, and `entries` arrives key-sorted,
    /// so ties resolve identically on every launch.
    private func freshest(
        among entries: [(String, [String: Any])],
        matching predicate: (String) -> Bool
    ) -> (String, [String: Any])? {
        entries
            .filter { predicate($0.0) }
            .max { electionRank($0.1["expiresAt"]) < electionRank($1.1["expiresAt"]) }
    }

    /// `expiresAt` is epoch **milliseconds**, or nil when absent/unparseable. A string-encoded
    /// number is accepted too (Electron has emitted `expiresAt` both ways) — otherwise a valid but
    /// stringified expiry would read as unknown and rank last in election, letting a stale entry win.
    private func parsedExpiry(from any: Any?) -> Date? {
        let millis: Double? = if let number = any as? NSNumber {
            number.doubleValue
        } else if let double = any as? Double {
            double
        } else if let string = any as? String {
            Double(string)
        } else {
            nil
        }
        return millis.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// The chosen entry's expiry. A missing/odd value → `.distantFuture` so the poller still
    /// attempts the call; a genuinely dead token then fails 401 (terminal).
    private func expiry(from any: Any?) -> Date {
        parsedExpiry(from: any) ?? .distantFuture
    }

    /// Ranking for **election** among sibling entries: a parseable expiry ranks by its value, a
    /// missing/odd one ranks below every valid expiry (`.distantPast`) — the opposite sentinel to
    /// `expiry`. Reusing `.distantFuture` here would let a malformed entry, whose expiry is
    /// unknowable, outrank a genuinely valid token in the same cache and get elected over it.
    private func electionRank(_ any: Any?) -> Date {
        parsedExpiry(from: any) ?? .distantPast
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

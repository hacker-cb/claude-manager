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

    /// Scratch state threaded through `SafeStorageKeyStore.key`'s `accepts` probe: the most recent
    /// rejection reason, so a not-v10 / corrupt blob is reported precisely rather than as a generic
    /// wrong-key `decryptFailed`. `@unchecked Sendable` because the probe closure is `@Sendable`,
    /// but it runs synchronously inside the actor before `key` returns — no concurrent access.
    private final class ProbeResult: @unchecked Sendable {
        private var failure: TokenProviderError?

        /// What to report, defaulting to wrong-key when nothing was recorded.
        var lastFailure: TokenProviderError {
            failure ?? .decryptFailed(.decryptFailed)
        }

        /// Record a rejection, **keeping wrong-key evidence once seen**.
        ///
        /// `.decryptFailed(.decryptFailed)` is the only symptom that means the key itself is wrong,
        /// and `UsageService.shouldSelfHeal` keys off exactly it. Now that several blobs are tried
        /// per candidate, a later one that unpads by luck (~1/256) and isn't JSON would otherwise
        /// overwrite that evidence with `.malformedCache` — and silently suppress the fleet's
        /// recovery from a rotated key, which is the one thing this reason is load-bearing for.
        func record(_ next: TokenProviderError) {
            if case .decryptFailed(.decryptFailed)? = failure { return }
            failure = next
        }
    }

    public func read(_ binding: TokenBinding, interactive: Bool) async -> BindingReading {
        guard let configData = try? Data(contentsOf: binding.configURL),
              let root = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]
        else {
            // The one failure that costs us the hint too, and correctly so: there is no file to
            // have hinted anything.
            return BindingReading(token: .failure(.configUnreadable))
        }
        // Lifted **before** the token work, so it survives every early return below it. That is the
        // whole point of reading the file into a reading rather than a result: five of the six ways
        // this can fail leave the account perfectly nameable, and used to discard the name anyway.
        return await BindingReading(
            token: tokenResult(root: root, binding: binding, interactive: interactive),
            hintedAccountUUID: accountHint(in: root)
        )
    }

    /// `lastKnownAccountUuid`, if the file carries a UUID.
    ///
    /// **Parsed**, not measured. A length test would let 36 arbitrary characters through — and
    /// costs nothing less than this one — while `UUID(uuidString:)` says exactly what the name
    /// claims. Rejecting a non-canonical spelling loses nothing either: this value's only use is to
    /// match `account_profiles.account_uuid`, which comes from `/oauth/profile` in canonical form,
    /// so anything that fails to parse could never have matched.
    ///
    /// It is still a filter rather than a sanitizer, and the distinction is worth keeping straight:
    /// what actually bounds this value is downstream — `UsageService.hintedAccounts` uses it only
    /// as a **lookup key** into answers this machine already holds, so the raw string never becomes
    /// an account uuid, never reaches a file path or a URL, and only ever meets SQLite through a
    /// bound parameter. Parsing here just drops the obviously-wrong before it costs a lookup.
    private func accountHint(in root: [String: Any]) -> String? {
        guard let hint = root[CoreConstants.desktopAccountHintKey] as? String,
              UUID(uuidString: hint) != nil
        else { return nil }
        return hint
    }

    private func tokenResult(
        root: [String: Any],
        binding: TokenBinding,
        interactive: Bool
    ) async -> Result<DesktopToken, TokenProviderError> {
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
        //
        // Each blob keeps its **position**, not just its payload: `present[0]` is the live cache
        // (v2 wherever it exists), and whether that particular one is among the caches we manage to
        // read is what decides a sign-out below. Dropping the position — as a plain `compactMap`
        // did — is what let a legacy sibling answer for a login it knows nothing about.
        let blobs: [(isLive: Bool, data: Data)] = present.enumerated().compactMap { index, value in
            Data(base64Encoded: value).map { (isLive: index == 0, data: $0) }
        }
        guard !blobs.isEmpty else { return .failure(.malformedCache) }

        // Resolve the safeStorage key by which keychain account's password actually decrypts these
        // blobs — the account name under the service varies by Claude Desktop version (`Claude` vs
        // `Claude Key`), and a stale item can sit beside the live one, so the store enumerates them
        // and this probe picks the live one. A cached key is returned as-is; only the first
        // resolution runs the probe, which records the precise reason on rejection.
        let probe = ProbeResult()
        let key: Data
        do {
            key = try await keyStore.key(interactive: interactive) { [decryptor] candidate in
                // **Any** blob proving the candidate is enough. Judging the key by the first one
                // alone meant a corrupt v2 condemned the whole binding: every keychain account was
                // rejected and the failure reported, while a perfectly good v1 sat unread in the
                // same file — the very thing reading both keys is supposed to prevent.
                for blob in blobs {
                    switch decryptor.decrypt(v10Blob: blob.data, key: candidate) {
                    case let .success(plaintext):
                        // Accept only if it decrypts to a JSON *object* — the token cache's shape —
                        // not merely on PKCS7 success. A wrong key (a stale account tried before the
                        // live one) unpads cleanly ~1/256 of the time on garbage; accepting on
                        // decrypt alone would cache that garbage key and never reach the live
                        // account. Requiring valid JSON makes a false accept astronomically unlikely.
                        guard (try? JSONSerialization.jsonObject(with: plaintext)) is [String: Any]
                        else {
                            probe.record(.malformedCache)
                            continue
                        }
                        return true
                    case let .failure(error):
                        probe.record(.decryptFailed(error))
                        continue
                    }
                }
                return false
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

        // Read every cache this profile has, not just the one that happened to come first. No side
        // effects on failure: the shared fleet key must not be invalidated for one binding's corrupt
        // blob — rotated-key self-heal is handled fleet-wide by UsageService (invalidate once only
        // when *every* binding fails), where the whole-fleet view can tell rotation from a single
        // corrupt blob.
        var caches: [[String: Any]] = []
        // Whether the **live** cache is one of the ones we read. Only it may claim a sign-out; the
        // guard below is where that matters.
        var readLiveCache = false
        // Same discipline as the probe: wrong-key evidence, once seen, is not overwritten by a
        // luckier sibling — see `ProbeResult.record`.
        let outcome = ProbeResult()
        // A value that was not base64 at all never reaches the loop below, but it is still a cache
        // that defeated us — and once the sign-out guard can rest on `outcome`, leaving it
        // unrecorded is not merely imprecise. `lastFailure` substitutes `.decryptFailed` for
        // silence, so a half-written `config.json` beside an empty sibling would announce a
        // **rotated safeStorage key**: the one symptom `UsageService.shouldSelfHeal` acts on, making
        // the whole fleet drop and re-read its cached key over one truncated file. Recorded first so
        // a genuine wrong-key symptom from a sibling still outranks it.
        if blobs.count < present.count { outcome.record(.malformedCache) }
        for blob in blobs {
            switch decryptor.decrypt(v10Blob: blob.data, key: key) {
            case let .success(plaintext):
                if let cache = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] {
                    caches.append(cache)
                    if blob.isLive { readLiveCache = true }
                } else {
                    outcome.record(.malformedCache)
                }
            case let .failure(error):
                outcome.record(.decryptFailed(error))
            }
        }
        guard !caches.isEmpty else { return .failure(outcome.lastFailure) }

        // An empty map is what Desktop's logout leaves behind — it rewrites the key rather than
        // removing it. An emptied v2 can still sit beside a v1 holding the entries, so entries
        // anywhere outrank emptiness and only a profile with none of them is a sign-out candidate.
        let populated = caches.filter { !$0.isEmpty }
        guard !populated.isEmpty else {
            // `.signedOut` is a **positive claim about the login**, and only the live cache can make
            // it: it costs the binding its figures, detaches it from its account's fan-out, and
            // tells the user to sign in. An empty legacy blob sitting beside a v2 we could not
            // decrypt supports none of that — the cache that would have said whether this profile
            // is signed in is precisely the one that defeated us, and a profile that is signed in
            // gets told to sign in again to no effect. Reporting the failure instead is also what
            // keeps `UsageService.shouldSelfHeal` able to see a rotated key and recover the fleet.
            //
            // The mirror case is why this discriminates rather than treating any failure as
            // disqualifying: a live cache that decrypted and is empty *is* a logout, and an
            // unreadable legacy blob left behind by an old rotation must not turn it into a fault.
            return .failure(readLiveCache ? .signedOut : outcome.lastFailure)
        }

        // Every populated cache gets a turn, not just the first. Election can decline one — a cache
        // holding nothing but another client's entries, or an elected entry whose token is an empty
        // string — and a decline used to end the read then and there, with a usable token sitting
        // decrypted in the sibling this same loop had already read into memory. `.noUsableEntry`
        // keeps its meaning of "entries exist, none of them ours", which is why it is not a sign-in
        // prompt: it now says so about *all* of this profile's caches rather than one of them.
        guard let entry = populated.compactMap({ usableEntry(in: $0) }).first else {
            return .failure(.noUsableEntry)
        }

        return .success(DesktopToken(
            token: entry.token,
            expiresAt: expiry(from: entry.value["expiresAt"]),
            scopes: scopes(fromComposite: entry.composite),
            organizationUUID: organizationUUID(fromComposite: entry.composite),
            subscriptionType: entry.value["subscriptionType"] as? String,
            rateLimitTier: entry.value["rateLimitTier"] as? String,
            bindingID: binding.id
        ))
    }

    /// An elected cache entry that has cleared both bars: something matched, and what matched holds
    /// a token. A type rather than a tuple because the three parts travel together out of
    /// `usableEntry(in:)` and each is read by name at the construction site below.
    private struct ElectedEntry {
        let composite: String
        let value: [String: Any]
        let token: String
    }

    /// The entry to use out of one decrypted cache — whatever `pickEntry` elects, and only when it
    /// actually carries a token.
    ///
    /// Nil means "nothing usable in *this* cache", which is a reason to look at the next one rather
    /// than a verdict about the profile. Folding the empty-token check in here is what makes that
    /// true of both ways a cache can come up short.
    private func usableEntry(in cache: [String: Any]) -> ElectedEntry? {
        guard let (composite, value) = pickEntry(from: cache),
              let token = value["token"] as? String, !token.isEmpty
        else { return nil }
        return ElectedEntry(composite: composite, value: value, token: token)
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

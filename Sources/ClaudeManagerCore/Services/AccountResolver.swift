import Foundation

/// One deduplicated account: the elected token to fetch usage with, plus every binding that
/// resolved to it. `identity` is provisional until `/profile` answers — its `uuid` is the token's
/// fingerprint, a per-token placeholder — after which `UsageService` fills the authoritative
/// account UUID, email, and display name.
public struct ResolvedAccount: Sendable, Equatable {
    public var identity: AccountIdentity
    public var token: DesktopToken
    /// Every binding (profile / default) that maps to this account — so one `/usage` call
    /// covers them all, and the UI can show "shared with N profiles".
    public var bindingIDs: [String]

    public init(
        identity: AccountIdentity,
        token: DesktopToken,
        bindingIDs: [String]
    ) {
        self.identity = identity
        self.token = token
        self.bindingIDs = bindingIDs
    }
}

/// Result of resolving a set of bindings: the deduped accounts, plus why each failed binding
/// couldn't produce a token (for a per-binding "login needed" / Doctor note).
public struct ResolvedAccounts: Sendable, Equatable {
    public var accounts: [ResolvedAccount]
    public var failures: [String: TokenProviderError]

    public init(accounts: [ResolvedAccount], failures: [String: TokenProviderError]) {
        self.accounts = accounts
        self.failures = failures
    }
}

/// Turns a list of bindings (Desktop profiles + the default account) into one entry per account.
/// **Reconcile-before-group:** every binding's token is decrypted locally first, then bindings are
/// merged only where it is *provably* safe — an identical token (same fingerprint ⇒ same account).
/// Distinct tokens stay separate here and are unified later, in `regroup`, on the authoritative
/// account uuid `/profile` returns — so N profiles on one login still yield one `/usage` call,
/// sourced from the healthiest token, without ever merging on the fallible `lastKnownAccountUuid`.
public struct AccountResolver: Sendable {
    private let provider: TokenProvider

    public init(provider: TokenProvider) {
        self.provider = provider
    }

    public func resolve(
        bindings: [TokenBinding],
        interactive: Bool = false,
        now: Date = Date()
    ) async -> ResolvedAccounts {
        var tokensByBinding: [(binding: TokenBinding, token: DesktopToken)] = []
        var failures: [String: TokenProviderError] = [:]

        for binding in bindings {
            // Stop reading keychain tokens the moment the master switch cancels the pass; the
            // caller checks cancellation again before fetching, so a partial resolve fetches
            // nothing.
            if Task.isCancelled { break }
            switch await provider.token(for: binding, interactive: interactive) {
            case let .success(token):
                tokensByBinding.append((binding, token))
            case let .failure(error):
                failures[binding.id] = error
            }
        }

        // Group by token fingerprint (identical tokens = one account), electing one token per
        // group. Dictionary grouping is order-independent, so sort the output for a stable result.
        let grouped = Dictionary(grouping: tokensByBinding) { groupingKey(for: $0.token) }
        let accounts = grouped
            .map { _, members in resolvedAccount(from: members, now: now) }
            .sorted { $0.identity.uuid < $1.identity.uuid }

        return ResolvedAccounts(accounts: accounts, failures: failures)
    }

    /// Fold accounts that `/profile` has proven belong together (same authoritative uuid) into one:
    /// union their bindings, re-elect the healthiest token, keep the richest identity. Run **after**
    /// `identified` settles uuids, so the fold key is authoritative — not the per-token fingerprint
    /// a still-provisional account carries, which is unique and never folds.
    ///
    /// This is what makes "N launchers, one login" cost one account: each launcher carries its own
    /// token, so they resolve separately (distinct fingerprints); only once `/profile` maps each
    /// token to the same account uuid can they be unified. Without this pass one login would issue
    /// N `/usage` calls on *every* poll, store N rows, and never show "shared with N profiles".
    public func regroup(_ accounts: [ResolvedAccount], now: Date) -> [ResolvedAccount] {
        guard accounts.count > 1 else { return accounts }
        return Dictionary(grouping: accounts, by: { $0.identity.uuid })
            .map { _, group in merged(group, now: now) }
            .sorted { $0.identity.uuid < $1.identity.uuid }
    }

    private func merged(_ group: [ResolvedAccount], now: Date) -> ResolvedAccount {
        guard group.count > 1 else { return group[0] }
        let elected = elect(group.map(\.token), now: now)
        var result = group.first { $0.token.bindingID == elected.bindingID } ?? group[0]
        result.token = elected
        result.bindingIDs = group.flatMap(\.bindingIDs).sorted()
        // Prefer an identity that `/profile` actually named; the uuid is shared by construction.
        result.identity = group.first { $0.identity.accountLabel != nil }?.identity ?? result.identity
        return result
    }

    /// The local dedup key: the token's fingerprint. Two bindings merge here only when they hold
    /// the *identical* token — which proves the same account with no network round-trip (a cloned
    /// user-data dir is the common case). Distinct tokens are never merged locally: even siblings
    /// on one login carry different tokens, and neither the shared `organizationUUID` (a Team org
    /// holds many accounts) nor the config's `lastKnownAccountUuid` hint (it can lag the actual
    /// token) proves same-account — merging on either would file one account's usage under another.
    /// Distinct-token siblings are unified instead in `regroup`, on the authoritative uuid
    /// `/profile` returns, the only signal that proves two different tokens share one account.
    private func groupingKey(for token: DesktopToken) -> String {
        token.fingerprint
    }

    private func resolvedAccount(
        from members: [(binding: TokenBinding, token: DesktopToken)],
        now: Date
    ) -> ResolvedAccount {
        let elected = elect(members.map(\.token), now: now)
        let bindingIDs = members.map(\.binding.id).sorted()
        // Provisional identity until `/profile` answers: the uuid is the token's fingerprint — a
        // per-token placeholder, so `regroup` can only ever fold accounts an authoritative
        // `/profile` uuid has already unified, never two distinct tokens sharing a stale hint.
        let identity = AccountIdentity(
            uuid: elected.fingerprint,
            organizationUuid: elected.organizationUUID,
            subscriptionType: elected.subscriptionType,
            rateLimitTier: elected.rateLimitTier
        )
        return ResolvedAccount(identity: identity, token: elected, bindingIDs: bindingIDs)
    }

    /// Election ladder: a valid token (unexpired AND has the inference scope) beats an invalid
    /// one; then the latest expiry (a proxy for "most recently refreshed"); then a stable
    /// binding id. Running-status is deliberately absent — it sets poll cadence, not which
    /// token is healthiest. "login needed" is left to the caller when a group has only expired
    /// tokens (this still elects the least-bad, and the caller skips the call on expiry).
    private func elect(_ tokens: [DesktopToken], now: Date) -> DesktopToken {
        tokens.max { lhs, rhs in
            let lhsValid = !lhs.isExpired(now: now) && lhs.hasInferenceScope
            let rhsValid = !rhs.isExpired(now: now) && rhs.hasInferenceScope
            if lhsValid != rhsValid { return rhsValid } // a valid token sorts as the max
            if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
            return lhs.bindingID > rhs.bindingID
        } ?? tokens[0]
    }
}

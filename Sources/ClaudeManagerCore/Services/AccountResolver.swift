import Foundation

/// One deduplicated account: the elected token to fetch usage with, plus every binding that
/// resolved to it. `identity` is provisional — its `uuid` is the best *local* hint (the
/// token's org, or the config `lastKnownAccountUuid`); `/profile` (later, in `UsageService`)
/// confirms the authoritative account UUID and fills email/display name.
public struct ResolvedAccount: Sendable, Equatable {
    public var identity: AccountIdentity
    public var token: DesktopToken
    /// Every binding (profile / default) that maps to this account — so one `/usage` call
    /// covers them all, and the UI can show "shared with N profiles".
    public var bindingIDs: [String]

    public init(identity: AccountIdentity, token: DesktopToken, bindingIDs: [String]) {
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

/// Turns a list of bindings (Desktop profiles + the default account) into one entry per
/// account. **Reconcile-before-group:** every binding's token is decrypted locally first, the
/// account is keyed by the *token's* organization (the config `lastKnownAccountUuid` is only a
/// fallback hint), and within a group the best token is elected — so N profiles on one account
/// yield exactly one `/usage` call, sourced from a healthy token.
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
            switch await provider.token(for: binding, interactive: interactive) {
            case let .success(token):
                tokensByBinding.append((binding, token))
            case let .failure(error):
                failures[binding.id] = error
            }
        }

        // Group by the token's account key, then elect one token per group. Dictionary
        // grouping is order-independent, so sort the output for a stable, testable result.
        let grouped = Dictionary(grouping: tokensByBinding) { groupingKey(for: $0.token) }
        let accounts = grouped
            .map { _, members in resolvedAccount(from: members, now: now) }
            .sorted { $0.identity.uuid < $1.identity.uuid }

        return ResolvedAccounts(accounts: accounts, failures: failures)
    }

    /// The dedup key: the token's organization UUID (authoritative, from the signed cache),
    /// then the config's account-UUID hint, then the binding id (its own group — can't dedup).
    private func groupingKey(for token: DesktopToken) -> String {
        token.organizationUUID ?? token.lastKnownAccountUUID ?? token.bindingID
    }

    private func resolvedAccount(
        from members: [(binding: TokenBinding, token: DesktopToken)],
        now: Date
    ) -> ResolvedAccount {
        let elected = elect(members.map(\.token), now: now)
        let bindingIDs = members.map(\.binding.id).sorted()
        // Provisional identity: account UUID from the best local hint (config hint, else org).
        let identity = AccountIdentity(
            uuid: elected.lastKnownAccountUUID ?? elected.organizationUUID ?? elected.bindingID,
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

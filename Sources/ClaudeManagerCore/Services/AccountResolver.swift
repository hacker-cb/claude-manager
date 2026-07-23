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
    /// True when no local account-UUID hint was available, so `identity.uuid` is merely the
    /// binding id. `UsageService` asks `/profile` for the authoritative UUID before anything
    /// persistent (throttle state, samples, the notification ledger) is keyed on it.
    public var isProvisionalIdentity: Bool

    public init(
        identity: AccountIdentity,
        token: DesktopToken,
        bindingIDs: [String],
        isProvisionalIdentity: Bool = false
    ) {
        self.identity = identity
        self.token = token
        self.bindingIDs = bindingIDs
        self.isProvisionalIdentity = isProvisionalIdentity
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

    /// Fold already-resolved accounts that share an identity uuid into one: union their bindings,
    /// re-elect the healthiest token, and keep the richest identity. Run **after** `/profile`
    /// settles provisional identities.
    ///
    /// This is what makes "N launchers, one login" cost one account. Until Claude writes
    /// `lastKnownAccountUuid` into each profile there is nothing local tying those launchers
    /// together — each carries its own token — so they resolve separately, and without this pass
    /// one login would issue N `/usage` calls on *every* poll (differing token fingerprints even
    /// read as a re-login, bypassing the 60s floor), store N rows for one account, and never show
    /// "shared with N profiles".
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
        // Provisional only while *every* member still is — one settled answer settles the group.
        result.isProvisionalIdentity = group.allSatisfy(\.isProvisionalIdentity)
        return result
    }

    /// The dedup key must identify the **account**, not the organization: in a Team/Enterprise
    /// org several profiles signed in as *different users* share one `organizationUUID` while
    /// being distinct accounts, so keying on the org collapses them and renders one account's
    /// limits for all of them. The config's account-UUID hint (`lastKnownAccountUuid`) is the
    /// only thing that identifies an account locally; without it a binding stands alone until
    /// `/profile` supplies the authoritative UUID (`UsageService.reconcileIdentity`).
    ///
    /// Deliberately asymmetric: over-splitting costs one extra `/usage` call for a moment,
    /// while collapsing shows the *wrong account's* numbers — so this errs toward splitting.
    private func groupingKey(for token: DesktopToken) -> String {
        token.lastKnownAccountUUID ?? token.bindingID
    }

    private func resolvedAccount(
        from members: [(binding: TokenBinding, token: DesktopToken)],
        now: Date
    ) -> ResolvedAccount {
        let elected = elect(members.map(\.token), now: now)
        let bindingIDs = members.map(\.binding.id).sorted()
        // With no local hint the uuid is just the binding id — provisional until `/profile`.
        let hinted = elected.lastKnownAccountUUID
        let identity = AccountIdentity(
            uuid: hinted ?? elected.bindingID,
            organizationUuid: elected.organizationUUID,
            subscriptionType: elected.subscriptionType,
            rateLimitTier: elected.rateLimitTier
        )
        return ResolvedAccount(
            identity: identity,
            token: elected,
            bindingIDs: bindingIDs,
            isProvisionalIdentity: hinted == nil
        )
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

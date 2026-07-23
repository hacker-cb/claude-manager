import Foundation
import Testing
@testable import ClaudeManagerCore

struct AccountResolverTests {
    /// Stub provider: canned result per binding id.
    private struct StubProvider: TokenProvider {
        let results: [String: Result<DesktopToken, TokenProviderError>]
        func token(
            for binding: TokenBinding,
            interactive _: Bool
        ) async -> Result<DesktopToken, TokenProviderError> {
            results[binding.id] ?? .failure(.configUnreadable)
        }
    }

    private func binding(_ id: String) -> TokenBinding {
        TokenBinding(id: id, configURL: URL(fileURLWithPath: "/tmp/\(id)/config.json"))
    }

    private func token(
        binding: String,
        org: String? = "org-A",
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000), // far future
        scopes: [String] = [CoreConstants.oauthInferenceScope, CoreConstants.oauthProfileScope],
        lastKnown: String? = nil
    ) -> DesktopToken {
        DesktopToken(
            token: "TK-\(binding)",
            expiresAt: expiresAt,
            scopes: scopes,
            organizationUUID: org,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            bindingID: binding,
            lastKnownAccountUUID: lastKnown
        )
    }

    private func resolve(
        _ results: [String: Result<DesktopToken, TokenProviderError>],
        now: Date = Date()
    ) async -> ResolvedAccounts {
        await AccountResolver(provider: StubProvider(results: results))
            .resolve(bindings: results.keys.sorted().map(binding), now: now)
    }

    // MARK: - Dedup

    @Test
    func sameOrgWithoutHintStaysProvisionalPerBinding() async {
        // Same org, no `lastKnownAccountUuid` on either side: the org does NOT identify an
        // account (a Team org holds many), so these must not collapse into one. They stand alone
        // as provisional identities until `/profile` supplies the authoritative UUID — over-
        // splitting costs an extra call, collapsing would render one account's limits for both.
        let result = await resolve([
            "p1": .success(token(binding: "p1", org: "org-A")),
            "p2": .success(token(binding: "p2", org: "org-A"))
        ])
        #expect(result.accounts.count == 2)
        let allProvisional = result.accounts.allSatisfy(\.isProvisionalIdentity)
        #expect(allProvisional)
        #expect(Set(result.accounts.map(\.identity.uuid)) == ["p1", "p2"])
    }

    @Test
    func separateOrgsAreSeparateAccounts() async {
        let result = await resolve([
            "p1": .success(token(binding: "p1", org: "org-A")),
            "p2": .success(token(binding: "p2", org: "org-B"))
        ])
        #expect(result.accounts.count == 2)
    }

    @Test
    func sameOrgDifferentAccountsAreNotCollapsed() async {
        // Two profiles in one Team/Enterprise org, signed in as different users: same org UUID,
        // different account UUIDs. They must stay separate accounts, not collapse to one.
        let result = await resolve([
            "userA": .success(token(binding: "userA", org: "shared-org", lastKnown: "acct-A")),
            "userB": .success(token(binding: "userB", org: "shared-org", lastKnown: "acct-B"))
        ])
        #expect(result.accounts.count == 2)
        #expect(Set(result.accounts.map(\.identity.uuid)) == ["acct-A", "acct-B"])
    }

    @Test
    func groupsByLastKnownWhenNoOrg() async {
        let result = await resolve([
            "p1": .success(token(binding: "p1", org: nil, lastKnown: "acct-9")),
            "p2": .success(token(binding: "p2", org: nil, lastKnown: "acct-9"))
        ])
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.identity.uuid == "acct-9")
        // A hinted identity is authoritative enough to key on — no `/profile` round-trip needed.
        #expect(result.accounts.first?.isProvisionalIdentity == false)
    }

    // MARK: - Election

    /// Election only happens *within* a group, so each test below shares one account hint — two
    /// profiles signed into the same account. Without it they'd resolve to separate accounts and
    /// the assertions would pass on sort order rather than on the election ladder.
    private static let sharedAccount = "acct-shared"

    @Test
    func electsValidOverExpired() async {
        let past = Date(timeIntervalSince1970: 1000)
        let result = await resolve([
            "expired": .success(token(binding: "expired", expiresAt: past, lastKnown: Self.sharedAccount)),
            "valid": .success(token(binding: "valid", lastKnown: Self.sharedAccount))
        ], now: Date(timeIntervalSince1970: 2000))
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.token.bindingID == "valid")
    }

    @Test
    func electsInferenceOverProfileOnly() async {
        let result = await resolve([
            "profileOnly": .success(token(
                binding: "profileOnly",
                scopes: [CoreConstants.oauthProfileScope],
                lastKnown: Self.sharedAccount
            )),
            "inference": .success(token(binding: "inference", lastKnown: Self.sharedAccount))
        ])
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.token.bindingID == "inference")
    }

    @Test
    func electsLatestExpiryAmongValidTokens() async {
        let soon = Date(timeIntervalSince1970: 3_000_000_000)
        let later = Date(timeIntervalSince1970: 4_000_000_000)
        let result = await resolve([
            "soon": .success(token(binding: "soon", expiresAt: soon, lastKnown: Self.sharedAccount)),
            "later": .success(token(binding: "later", expiresAt: later, lastKnown: Self.sharedAccount))
        ])
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.token.bindingID == "later")
    }

    @Test
    func allExpiredStillElectsLeastBad() async {
        let now = Date(timeIntervalSince1970: 5_000_000_000)
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let result = await resolve([
            "older": .success(token(binding: "older", expiresAt: older, lastKnown: Self.sharedAccount)),
            "newer": .success(token(binding: "newer", expiresAt: newer, lastKnown: Self.sharedAccount))
        ], now: now)
        // Both expired → still one account, elected token is the latest-expiry one; the caller
        // sees isExpired and skips the /usage call (login-needed), but dedup still holds.
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.token.bindingID == "newer")
        #expect(result.accounts.first?.token.isExpired(now: now) == true)
    }

    // MARK: - Failures

    @Test
    func recordsFailuresSeparatelyFromAccounts() async {
        let result = await resolve([
            "ok": .success(token(binding: "ok", org: "org-A")),
            "locked": .failure(.keychainUnavailable(.interactionNotAllowed)),
            "noLogin": .failure(.noTokenCache)
        ])
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["ok"])
        #expect(result.failures["locked"] == .keychainUnavailable(.interactionNotAllowed))
        #expect(result.failures["noLogin"] == .noTokenCache)
    }

    @Test
    func identityCarriesTokenDerivedFields() async {
        let result = await resolve([
            "p1": .success(token(binding: "p1", org: "org-A", lastKnown: "acct-1"))
        ])
        let identity = result.accounts.first?.identity
        #expect(identity?.uuid == "acct-1") // prefers the config account-uuid hint
        #expect(identity?.organizationUuid == "org-A")
        #expect(identity?.subscriptionType == "max")
    }
}

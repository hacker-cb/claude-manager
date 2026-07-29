import Foundation
import Testing
@testable import ClaudeManagerCore

struct AccountResolverTests {
    /// Stub provider: canned reading per binding id, with an optional config hint.
    private struct StubProvider: TokenProvider {
        let results: [String: Result<DesktopToken, TokenProviderError>]
        var hints: [String: String] = [:]

        func read(_ binding: TokenBinding, interactive _: Bool) async -> BindingReading {
            BindingReading(
                bindingID: binding.id,
                token: results[binding.id] ?? .failure(.configUnreadable),
                hintedAccountUUID: hints[binding.id]
            )
        }
    }

    private func binding(_ id: String) -> TokenBinding {
        TokenBinding(id: id, configURL: URL(fileURLWithPath: "/tmp/\(id)/config.json"))
    }

    private func token(
        binding: String,
        org: String? = "org-A",
        value: String? = nil,
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000), // far future
        scopes: [String] = [CoreConstants.oauthInferenceScope, CoreConstants.oauthProfileScope]
    ) -> DesktopToken {
        DesktopToken(
            token: value ?? "TK-\(binding)",
            expiresAt: expiresAt,
            scopes: scopes,
            organizationUUID: org,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            bindingID: binding
        )
    }

    private func resolve(
        _ results: [String: Result<DesktopToken, TokenProviderError>],
        hints: [String: String] = [:],
        now: Date = Date()
    ) async -> ResolvedAccounts {
        await AccountResolver(provider: StubProvider(results: results, hints: hints))
            .resolve(bindings: results.keys.sorted().map(binding), now: now)
    }

    /// A `ResolvedAccount` as it looks *after* `/profile` has settled its uuid — the input shape
    /// `regroup` sees, where account-folding and election actually happen.
    private func settled(_ token: DesktopToken, uuid: String) -> ResolvedAccount {
        ResolvedAccount(
            identity: AccountIdentity(uuid: uuid),
            token: token,
            bindingIDs: [token.bindingID]
        )
    }

    private func regroup(_ accounts: [ResolvedAccount], now: Date = Date()) -> [ResolvedAccount] {
        AccountResolver(provider: StubProvider(results: [:])).regroup(accounts, now: now)
    }

    // MARK: - Local dedup (resolve): merges identical tokens only

    @Test
    func identicalTokensCollapseToOneAccount() async {
        // A cloned user-data dir gives two bindings the *same* token — provably one account, so it
        // is safe to merge locally with no `/profile` round-trip.
        let result = await resolve([
            "p1": .success(token(binding: "p1", value: "SAME-TOKEN")),
            "p2": .success(token(binding: "p2", value: "SAME-TOKEN"))
        ])
        #expect(result.accounts.count == 1)
        #expect(result.accounts.first?.bindingIDs == ["p1", "p2"])
    }

    @Test
    func distinctTokensNeverMergeLocally() async {
        // Different tokens are never merged in `resolve` — not even sharing an org (a Team org
        // holds many accounts) or a config hint (it can lag the token), both of which could point
        // a token at the wrong account. They stand alone, keyed by fingerprint, until `/profile`
        // proves whether they share an account (`regroup`'s job).
        let result = await resolve([
            "userA": .success(token(binding: "userA", org: "shared-org")),
            "userB": .success(token(binding: "userB", org: "shared-org"))
        ])
        #expect(result.accounts.count == 2)
        #expect(Set(result.accounts.map(\.identity.uuid)).count == 2) // distinct fingerprints
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
    func provisionalUuidIsTheTokenFingerprint() async {
        // Until `/profile` answers, the account is identified only by its token — the fingerprint
        // is its uuid, and the token's coarse fields ride along.
        let tok = token(binding: "p1", org: "org-A")
        let result = await resolve(["p1": .success(tok)])
        #expect(result.accounts.first?.identity.uuid == tok.fingerprint)
        #expect(result.accounts.first?.identity.organizationUuid == "org-A")
        #expect(result.accounts.first?.identity.subscriptionType == "max")
        // Said outright rather than left to `uuid == fingerprint`: everything that reasons about a
        // binding with no readable token is a caller that has no fingerprint to compare against.
        #expect(result.accounts.first?.identity.isProvisional == true)
    }

    // MARK: - Account fold + election (regroup): by the authoritative /profile uuid

    // Election happens *within* a fold group, so each test below gives its accounts the same
    // settled uuid — two launchers `/profile` proved are one account.

    @Test
    func electsValidOverExpired() {
        let past = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 2000)
        let folded = regroup([
            settled(token(binding: "expired", value: "TK-expired", expiresAt: past), uuid: "acct"),
            settled(token(binding: "valid", value: "TK-valid"), uuid: "acct")
        ], now: now)
        #expect(folded.count == 1)
        #expect(folded.first?.token.bindingID == "valid")
    }

    @Test
    func electsInferenceOverProfileOnly() {
        let folded = regroup([
            settled(
                token(binding: "profileOnly", value: "TK-po", scopes: [CoreConstants.oauthProfileScope]),
                uuid: "acct"
            ),
            settled(token(binding: "inference", value: "TK-inf"), uuid: "acct")
        ])
        #expect(folded.count == 1)
        #expect(folded.first?.token.bindingID == "inference")
    }

    @Test
    func electsLatestExpiryAmongValidTokens() {
        let soon = Date(timeIntervalSince1970: 3_000_000_000)
        let later = Date(timeIntervalSince1970: 4_000_000_000)
        let folded = regroup([
            settled(token(binding: "soon", value: "TK-soon", expiresAt: soon), uuid: "acct"),
            settled(token(binding: "later", value: "TK-later", expiresAt: later), uuid: "acct")
        ])
        #expect(folded.count == 1)
        #expect(folded.first?.token.bindingID == "later")
    }

    @Test
    func allExpiredStillElectsLeastBad() {
        let now = Date(timeIntervalSince1970: 5_000_000_000)
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let folded = regroup([
            settled(token(binding: "older", value: "TK-older", expiresAt: older), uuid: "acct"),
            settled(token(binding: "newer", value: "TK-newer", expiresAt: newer), uuid: "acct")
        ], now: now)
        // Both expired → still one account, elected token is the latest-expiry one; the caller
        // sees isExpired and skips the /usage call (login-needed), but dedup still holds.
        #expect(folded.count == 1)
        #expect(folded.first?.token.bindingID == "newer")
        #expect(folded.first?.token.isExpired(now: now) == true)
    }

    @Test
    func distinctAuthoritativeUuidsAreNotFolded() {
        // The safety property behind the whole design: two tokens `/profile` mapped to *different*
        // accounts must never fold — even from bindings that once shared a config hint.
        let folded = regroup([
            settled(token(binding: "a", value: "TK-a"), uuid: "acct-A"),
            settled(token(binding: "b", value: "TK-b"), uuid: "acct-B")
        ])
        #expect(folded.count == 2)
        #expect(Set(folded.map(\.identity.uuid)) == ["acct-A", "acct-B"])
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

    // MARK: - The config hint travels, and changes nothing here

    @Test
    func aHintNeverMergesTwoDistinctTokens() async {
        // The rule the hint is *not* allowed to touch, now that it is in reach. Two profiles whose
        // configs name the same account still resolve as two accounts: only `/oauth/profile` may
        // fold distinct tokens, because a hint that lags a re-login would otherwise file one
        // account's usage under another.
        let shared = "80d91625-5c43-48ab-9892-3d6496250958"
        let result = await resolve(
            [
                "p1": .success(token(binding: "p1", value: "TK-A")),
                "p2": .success(token(binding: "p2", value: "TK-B"))
            ],
            hints: ["p1": shared, "p2": shared]
        )
        #expect(result.accounts.count == 2)
    }

    @Test
    func aHealthyFleetCarriesNoHintsAtAll() async {
        // The hint exists to explain a binding that cannot speak for itself. A profile whose token
        // came out fine has nothing to explain — and reading a file for it on every poll, forever,
        // would be a cost with no reader.
        let result = await resolve(
            ["p": .success(token(binding: "p"))],
            hints: ["p": "80d91625-5c43-48ab-9892-3d6496250958"]
        )
        #expect(result.hints.isEmpty)
    }

    @Test
    func aBindingThatCannotSpendItsTokenCarriesItsHint() async {
        // Both ways a binding ends up with an account it cannot prove: no token at all, and a token
        // too old to spend. The second is the less obvious one — it *resolved*, so it never appears
        // in `failures`, and without the hint it stands alone as a fingerprint-keyed phantom.
        let expired = token(binding: "stale", expiresAt: Date(timeIntervalSince1970: 1))
        let result = await resolve(
            [
                "locked": .failure(.keychainUnavailable(.interactionNotAllowed)),
                "stale": .success(expired),
                "live": .success(token(binding: "live"))
            ],
            hints: ["locked": "a-uuid", "stale": "b-uuid", "live": "c-uuid"],
            now: Date(timeIntervalSince1970: 1_000_000_000)
        )
        #expect(result.hints == ["locked": "a-uuid", "stale": "b-uuid"])
    }
}

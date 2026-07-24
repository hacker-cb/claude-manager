import Foundation

/// Working out **which account a token belongs to**, and naming it.
///
/// Split from the usage path because the two are gated separately: identity is per *token* (the
/// only key that exists before `/profile` answers), usage is per *account*. Sharing one gate let a
/// `/profile` rejection cancel a perfectly good `/usage` call, and left hint-less bindings
/// ungated entirely.
extension UsageService {
    // MARK: - Identity

    /// Name each account from the stored `/profile` answer, asking the network only for the ones
    /// that are still **provisional** — those have no usable storage key until it answers, and
    /// nothing can be merged or persisted for them until it does. A named-but-stale account is
    /// deliberately left alone here; `usage(for:)` refreshes it later, behind the throttle, so a
    /// backed-off account doesn't call `/profile` on every tick.
    func identified(
        _ accounts: [ResolvedAccount],
        now: Date,
        interactive: Bool
    ) async -> [ResolvedAccount] {
        let cutoff = now.addingTimeInterval(-Self.profileTTLSeconds)
        var settled: [ResolvedAccount] = []
        for account in accounts {
            // Stop issuing `/profile` calls the moment the master switch cancels the pass — the
            // remaining accounts keep whatever identity they arrived with, unfetched.
            if Task.isCancelled { break }
            let fingerprint = account.token.fingerprint
            // The token's own `/profile` answer, keyed by fingerprint, is the only authoritative
            // source of which account this token belongs to — so every distinct token confirms via
            // `/profile` once per TTL. Siblings on one login fold into one account afterwards
            // (`regroup` keys on the authoritative uuid `/profile` returns); a cloned sibling shares
            // the token, hence a fingerprint cache hit and no extra call. No local shortcut off a
            // config hint: it could name a token for the account it *used* to hold, not the one it
            // holds now, filing usage under the wrong account.
            if let cached = await history.profile(tokenFingerprint: fingerprint, fetchedAfter: cutoff) {
                settled.append(account.named(by: cached))
            } else if await mayCall(account, fingerprint: fingerprint, now: now, interactive: interactive) {
                await settled.append(fetchIdentity(account, fingerprint: fingerprint, now: now))
            } else {
                settled.append(account)
            }
        }
        return settled
    }

    /// Whether `/profile` may be called for this account right now: only while it is still
    /// provisional (a named account gains nothing here — `usage(for:)` refreshes a stale name
    /// later, behind the throttle), and only when the same expiry / backoff / floor gates that
    /// guard `/usage` allow it.
    ///
    /// Hoisting those gates is the whole point. They live in `usage(for:)`, which runs *after*
    /// this pass and so could never un-send a request this pass had already made: a launcher
    /// whose login is dead re-offered its token to `/profile` on every tick forever, and neither
    /// the 60s floor nor a 429 backoff applied to it.
    func mayCall(
        _ account: ResolvedAccount,
        fingerprint: String,
        now: Date,
        interactive: Bool
    ) async -> Bool {
        guard !account.token.isExpired(now: now) else { return false }
        let stored = await history.throttle(scope: Self.identityScope(fingerprint))
        return !Self.isBlocked(stored, fingerprint: fingerprint, now: now, interactive: interactive)
    }

    /// The shared "don't call right now" rule.
    ///
    /// A **terminal** park (401/403) is the only backoff anything lifts, and only through the two
    /// exits the docs promise: a re-login (new token) or an explicit user Refresh. A rate-limit or
    /// transport backoff belongs to the server or the network, never to us.
    ///
    /// The 60s floor is never bypassed — not even by a changed fingerprint. Once sibling launchers
    /// share one account the elected token flips whenever any of them refreshes its own OAuth
    /// token, with no re-login involved, and letting that discard the floor (or a standing 429
    /// window) would re-issue calls against an endpoint that had just throttled us.
    static func isBlocked(
        _ stored: ThrottleState?,
        fingerprint: String,
        now: Date,
        interactive: Bool
    ) -> Bool {
        guard let stored else { return false }
        let parked = stored.backoffUntil.map { $0 > now } ?? false
        if parked {
            // Lifting the park has to lift the floor with it. The `lastAttemptAt` in the way was
            // written by the very rejection being cleared, so leaving the floor in force made the
            // documented exit a no-op for its first minute — the user pressed Refresh, nothing
            // was fetched, and the account flipped from "sign in" to a falsely current state.
            return !clearsTerminal(stored, fingerprint, interactive)
        }
        if let last = stored.lastAttemptAt, now.timeIntervalSince(last) < floorSeconds { return true }
        return false
    }

    /// True when a standing **terminal** park should be lifted: the token changed (a real
    /// re-login) or the user explicitly asked. Never applies to a non-terminal backoff.
    static func clearsTerminal(
        _ stored: ThrottleState,
        _ fingerprint: String,
        _ interactive: Bool
    ) -> Bool {
        guard stored.backoffReason == .terminal else { return false }
        let reLogin = stored.tokenFingerprint != nil && stored.tokenFingerprint != fingerprint
        return reLogin || interactive
    }

    /// Ask `/profile` who this token belongs to, and store the answer. Costs one call per token
    /// per `profileTTLSeconds` — and one immediately after a re-login, since the fingerprint that
    /// keys the cache changes with the token.
    ///
    /// A failed lookup is not fatal: the account keeps whatever identity the local token gave it,
    /// and the next poll tries again. Usage is still fetched and shown — just unnamed, and for a
    /// binding with no account-UUID hint, still keyed provisionally.
    func fetchIdentity(
        _ account: ResolvedAccount,
        fingerprint: String,
        now: Date
    ) async -> ResolvedAccount {
        switch await client.fetchProfile(
            token: account.token.token,
            marketingVersion: marketingVersion
        ) {
        case let .success(profile):
            let identity = AccountIdentity(
                uuid: profile.accountUUID,
                email: profile.email,
                displayName: profile.displayName,
                // The token's own values win — exact where `/profile` exposes only coarse flags.
                organizationUuid: account.identity.organizationUuid ?? profile.organizationUUID,
                subscriptionType: account.identity.subscriptionType ?? profile.subscriptionType,
                rateLimitTier: account.identity.rateLimitTier ?? profile.rateLimitTier
            )
            await history.setProfile(identity, tokenFingerprint: fingerprint, fetchedAt: now)
            return account.named(by: identity)
        case let .failure(error):
            // Record every failure, but in the **identity** scope — never the account's. That
            // separation is the point: a `/profile` rejection (a token without `user:profile`
            // scope, an org that restricts it) must not cancel the `/usage` call for an account
            // whose usage endpoint answers perfectly well, and a transient blip on a *cosmetic*
            // name lookup must not cost the user their numbers. Recording it here is still
            // necessary, or the retry below in `usage(for:)` would ask again in the same pass and
            // a dead token would be re-offered on every tick forever.
            let scope = Self.identityScope(fingerprint)
            let stored = await history.throttle(scope: scope)
            let (until, reason) = Self.backoff(for: error, after: stored, now: now)
            await history.setThrottle(
                ThrottleState(
                    lastAttemptAt: now, backoffUntil: until,
                    backoffReason: reason, tokenFingerprint: fingerprint
                ),
                scope: scope
            )
            return account
        }
    }

    /// Error → how long to stay away, and why. Shared by the `/usage` and `/profile` paths so a
    /// failing identity lookup is throttled exactly like a failing usage fetch.
    static func backoff(
        for error: OAuthClientError,
        after stored: ThrottleState?,
        now: Date
    ) -> (until: Date, reason: BackoffReason) {
        switch error {
        case .unauthorized:
            (.distantFuture, .terminal)
        case let .rateLimited(retryAfter):
            (
                now.addingTimeInterval(
                    retryAfter.map { $0.clamped(to: retryAfterRange) } ?? nextBackoff(after: stored, now: now)
                ),
                .rateLimited
            )
        case .transport, .httpError, .malformedBody:
            (now.addingTimeInterval(nextBackoff(after: stored, now: now)), .offline)
        }
    }
}

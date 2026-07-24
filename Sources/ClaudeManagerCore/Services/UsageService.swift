import CryptoKit
import Foundation

/// Result of one refresh pass: usage per resolved account, plus the bindings that couldn't
/// produce a token at all (mapped by the app to a per-profile login-needed / no-source state).
public struct UsageRefreshResult: Sendable, Equatable {
    public var accounts: [AccountUsage]
    public var bindingFailures: [String: TokenProviderError]

    public init(accounts: [AccountUsage], bindingFailures: [String: TokenProviderError]) {
        self.accounts = accounts
        self.bindingFailures = bindingFailures
    }
}

/// Orchestrates one usage refresh: resolve+dedup bindings → per account, honor the throttle
/// (60s floor, 429/error backoff, terminal-on-401) and token expiry → fetch `/usage` → persist
/// → return the state the UI renders. **Stateless per refresh** (mirrors `ProfileStore`): it
/// owns no memory between calls; all durable state — the throttle window, the token fingerprint,
/// the last sample — lives in the `UsageHistoryStore` actor and is read back each tick. The app
/// owns the poll loop; this is a plain value it builds and calls.
public struct UsageService: Sendable {
    private let resolver: AccountResolver
    private let client: AnthropicOAuthClient
    private let keyStore: SafeStorageKeyStore
    private let history: UsageHistoryStore
    private let marketingVersion: String

    /// Minimum seconds between per-account fetches — also throttles a mashed manual Refresh.
    public static let floorSeconds: TimeInterval = 60
    /// Backoff applied to a 429 with no `Retry-After`, or the first transport/error backoff.
    public static let defaultBackoffSeconds: TimeInterval = 300
    /// Backoff ceiling — errors grow the window but never past this.
    public static let maxBackoffSeconds: TimeInterval = 1800
    /// `Retry-After` is clamped into this range.
    public static let retryAfterRange: ClosedRange<TimeInterval> = 60 ... 3600
    /// The adaptive fast lane: while an account is running, polls no slower than this.
    public static let adaptiveFloorSeconds: TimeInterval = 5 * 60
    /// Background cadence when the user hasn't chosen one. The settings picker offers this
    /// among its presets, so the two can't disagree about what "default" means.
    public static let defaultPollMinutes = 30
    /// How long a stored `/profile` answer is trusted. A re-login invalidates it immediately
    /// (the fingerprint changes), so this only covers what can change *under the same token* —
    /// a renamed account, a changed email, a moved plan — at one call per account per day.
    public static let profileTTLSeconds: TimeInterval = 24 * 3600

    /// Seconds until the next poll for a given interval. `minutes` (floored at 1) in seconds,
    /// dropped to the adaptive 5-min lane while an account is running — bounded by the interval
    /// so a longer interval is never made *faster* by adaptivity. `minutes == 0` (manual-only)
    /// is the caller's to short-circuit before scheduling; here it floors to one minute.
    public static func pollIntervalSeconds(
        minutes: Int,
        adaptiveEnabled: Bool,
        anyRunning: Bool
    ) -> TimeInterval {
        let base = TimeInterval(max(1, minutes) * 60)
        guard adaptiveEnabled, anyRunning else { return base }
        return min(base, adaptiveFloorSeconds)
    }

    public init(
        resolver: AccountResolver,
        client: AnthropicOAuthClient,
        keyStore: SafeStorageKeyStore,
        history: UsageHistoryStore,
        marketingVersion: String
    ) {
        self.resolver = resolver
        self.client = client
        self.keyStore = keyStore
        self.history = history
        self.marketingVersion = marketingVersion
    }

    public func refresh(
        bindings: [TokenBinding],
        now: Date = Date(),
        interactive: Bool = false
    ) async -> UsageRefreshResult {
        var resolved = await resolver.resolve(bindings: bindings, interactive: interactive, now: now)

        // Fleet-level key self-heal: if EVERY binding failed to *decrypt* (a rotated
        // safeStorage key, not one corrupt blob), invalidate the shared key once and retry.
        // Doing this here — with the whole-fleet view — avoids one corrupt account poisoning
        // a key that decrypts the others (why the provider no longer invalidates per-binding).
        if Self.shouldSelfHeal(resolved) {
            await keyStore.invalidate()
            resolved = await resolver.resolve(bindings: bindings, interactive: interactive, now: now)
        }

        // Settle identities *before* any usage is fetched, then fold the ones that turn out to be
        // the same account. Order matters: N launchers on one login only reveal themselves as one
        // account once `/profile` has answered, and folding after fetching would already have
        // spent N calls and stored N rows for it.
        let named = await identified(resolved.accounts, now: now, interactive: interactive)
        let settled = resolver.regroup(named, now: now)

        var accounts: [AccountUsage] = []
        for account in settled {
            await accounts.append(usage(for: account, now: now, interactive: interactive))
        }
        return UsageRefreshResult(accounts: accounts, bindingFailures: resolved.failures)
    }

    // MARK: - Identity

    /// Name each account from the stored `/profile` answer, asking the network only for the ones
    /// that are still **provisional** — those have no usable storage key until it answers, and
    /// nothing can be merged or persisted for them until it does. A named-but-stale account is
    /// deliberately left alone here; `usage(for:)` refreshes it later, behind the throttle, so a
    /// backed-off account doesn't call `/profile` on every tick.
    private func identified(
        _ accounts: [ResolvedAccount],
        now: Date,
        interactive: Bool
    ) async -> [ResolvedAccount] {
        let cutoff = now.addingTimeInterval(-Self.profileTTLSeconds)
        var settled: [ResolvedAccount] = []
        for account in accounts {
            let fingerprint = Self.fingerprint(account.token.token)
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
    private func mayCall(
        _ account: ResolvedAccount,
        fingerprint: String,
        now: Date,
        interactive: Bool
    ) async -> Bool {
        guard account.isProvisionalIdentity, !account.token.isExpired(now: now) else { return false }
        let stored = await history.throttle(accountUUID: account.identity.uuid)
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
        if parked, !clearsTerminal(stored, fingerprint, interactive) { return true }
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

    // MARK: - Per account

    private func usage(for resolved: ResolvedAccount, now: Date, interactive: Bool) async -> AccountUsage {
        let token = resolved.token
        // Expired token → call nothing at all (not even `/profile`, which would 401); the account
        // needs a fresh login. Served from whatever key we have.
        if token.isExpired(now: now) {
            let stale = await history.latest(accountUUID: resolved.identity.uuid)
            return resolved.usage(stale, state: .loginNeeded)
        }

        // The identity arrives already settled (see `identified`); all that's left is to notice
        // whether it still lacks a *fresh* name, which is refreshed below — after the throttle
        // gates, so it rides along with a `/usage` call instead of firing on a backed-off tick.
        let fingerprint = Self.fingerprint(token.token)
        let cutoff = now.addingTimeInterval(-Self.profileTTLSeconds)
        let named = await history.profile(tokenFingerprint: fingerprint, fetchedAfter: cutoff) != nil
        var account = resolved

        var uuid = account.identity.uuid
        let stored = await history.throttle(accountUUID: uuid)
        let latest = await history.latest(accountUUID: uuid)

        let context = PollContext(
            now: now, fingerprint: fingerprint, stored: stored,
            latest: latest, interactive: interactive
        )
        // Standing backoff still active → serve stale, rendering the *original* cause (a
        // transport backoff must not read back as a 429).
        if let parked = Self.parkedState(context) {
            return account.usage(latest, state: parked)
        }
        // Inside the 60s floor: we already hold the newest values the API would hand back, and
        // chose not to re-ask. Nothing failed, so this is *not* staleness — reporting it as such
        // made a normal poll cadence read as a problem ("stale · 4 min ago" on data that was
        // simply as fresh as the floor allows). The age still shows, via `capturedAt`.
        //
        // No snapshot to serve means the history is unreadable (the store degrades to memory for
        // the throttle but not for samples), which is neither a missing token source nor a
        // keychain problem — saying `.noSource` here made the app blame the keychain and offer a
        // fix that cannot work. Report it as current-with-nothing-yet instead.
        if let last = stored?.lastAttemptAt, now.timeIntervalSince(last) < Self.floorSeconds {
            return account.usage(latest, state: .fresh)
        }

        // Past every gate, so a `/usage` call is happening regardless: this is the moment to
        // refresh a missing or expired name too, which keeps the `/profile` call inside the same
        // backoff and floor that protect `/usage` instead of firing on every throttled tick.
        if !named {
            account = await fetchIdentity(account, fingerprint: fingerprint, now: now)
            // A late answer can settle a still-provisional account onto its real uuid, and every
            // write below must follow it — keyed on the stale binding id, the sample and throttle
            // land where the next tick never looks, orphaning the row and losing the floor.
            uuid = account.identity.uuid
        }

        switch await client.fetchUsage(
            token: token.token,
            marketingVersion: marketingVersion,
            capturedAt: now
        ) {
        case let .success(fetch):
            let sample = UsageSample(
                accountUUID: uuid, capturedAt: now, snapshot: fetch.snapshot,
                source: "desktop:\(token.bindingID)"
            )
            await history.record(sample, rawBody: fetch.rawBody)
            await history.setThrottle(
                ThrottleState(lastAttemptAt: now, backoffUntil: nil, tokenFingerprint: fingerprint),
                accountUUID: uuid
            )
            return AccountUsage(
                identity: account.identity, snapshot: fetch.snapshot, state: .fresh,
                bindingIDs: account.bindingIDs
            )
        case let .failure(error):
            return await handleFailure(error, account: account, context: context)
        }
    }

    /// Ask `/profile` who this token belongs to, and store the answer. Costs one call per token
    /// per `profileTTLSeconds` — and one immediately after a re-login, since the fingerprint that
    /// keys the cache changes with the token.
    ///
    /// A failed lookup is not fatal: the account keeps whatever identity the local token gave it,
    /// and the next poll tries again. Usage is still fetched and shown — just unnamed, and for a
    /// binding with no account-UUID hint, still keyed provisionally.
    private func fetchIdentity(
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
            // Park a **terminal** rejection, and only that. A dead token would otherwise be
            // re-offered to `/profile` on every tick forever, and 401 here means 401 for `/usage`
            // too, so the account genuinely needs a sign-in.
            //
            // Every other failure is left unrecorded on purpose: `/usage` runs next in this same
            // pass and records its own backoff if the endpoint is really unwell, so writing one
            // here would only mean a transient blip on a *cosmetic* name lookup costing the user
            // their numbers for the next five minutes.
            let (until, reason) = Self.backoff(for: error, after: nil, now: now)
            guard reason == .terminal else { return account }
            await history.setThrottle(
                ThrottleState(
                    lastAttemptAt: now, backoffUntil: until,
                    backoffReason: reason, tokenFingerprint: fingerprint
                ),
                accountUUID: account.identity.uuid
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

    /// The per-account state the gate and the failure handler need, bundled to keep the parameter
    /// lists small.
    private struct PollContext {
        let now: Date
        let fingerprint: String
        let stored: ThrottleState?
        let latest: UsageSample?
        var interactive = false
    }

    /// The state to serve while a standing backoff holds, or nil when none holds — or when it is
    /// a terminal park that a re-login or an explicit Refresh lifts.
    private static func parkedState(_ context: PollContext) -> UsageState? {
        guard let stored = context.stored else { return nil }
        guard let until = stored.backoffUntil, until > context.now else { return nil }
        guard !clearsTerminal(stored, context.fingerprint, context.interactive) else { return nil }
        switch stored.backoffReason {
        case .terminal: return .loginNeeded
        case .rateLimited: return .rateLimited(until: until)
        case .offline, .none: return context.latest.map { .stale(since: $0.capturedAt) } ?? .offline
        }
    }

    private func handleFailure(
        _ error: OAuthClientError,
        account: ResolvedAccount,
        context: PollContext
    ) async -> AccountUsage {
        let uuid = account.identity.uuid
        let (now, fingerprint, stored, latest) = (
            context.now,
            context.fingerprint,
            context.stored,
            context.latest
        )
        // How long to stay away is shared with the `/profile` path; only the state the UI shows
        // is decided here. A terminal park stops polling until a re-login or an explicit Refresh.
        let (backoffUntil, reason) = Self.backoff(for: error, after: stored, now: now)
        let state: UsageState = switch error {
        case .unauthorized: .loginNeeded
        case .rateLimited: .rateLimited(until: backoffUntil)
        case .transport: .offline
        case .httpError, .malformedBody: latest.map { .stale(since: $0.capturedAt) } ?? .offline
        }

        await history.setThrottle(
            ThrottleState(
                lastAttemptAt: now, backoffUntil: backoffUntil,
                backoffReason: reason, tokenFingerprint: fingerprint
            ),
            accountUUID: uuid
        )
        return account.usage(latest, state: state)
    }

    // MARK: - Helpers

    /// Whole-fleet rotation signal: nothing resolved, and at least one binding failed in a way
    /// that only a **wrong key** explains.
    ///
    /// The evidence has to be exactly that. `CCCrypt` rejecting the PKCS7 padding
    /// (`.decryptFailed`) is the wrong-key symptom; a blob that isn't `v10` or isn't block-aligned
    /// is a *shape* problem — Claude changing its format, or a truncated file — which no amount of
    /// re-deriving the key will fix, and treating it as rotation re-read the keychain and
    /// re-derived PBKDF2 on every tick forever without ever succeeding.
    ///
    /// Bindings that failed for their own reasons (`.noTokenCache` from a launcher nobody signed
    /// into, `.configUnreadable`) are **ignored** rather than disqualifying. Requiring every
    /// failure to be crypto-related meant the always-present default-account binding — permanently
    /// `.noTokenCache` for anyone who only uses launchers — silently disabled recovery for the
    /// whole fleet, leaving a rotated key stuck behind a process-lifetime cache until relaunch.
    private static func shouldSelfHeal(_ resolved: ResolvedAccounts) -> Bool {
        guard resolved.accounts.isEmpty else { return false }
        return resolved.failures.values.contains(where: isWrongKeyEvidence)
    }

    /// The rule above, reachable from tests without staging a whole decrypt fleet.
    static func shouldSelfHealForTest(failures: [String: TokenProviderError]) -> Bool {
        shouldSelfHeal(ResolvedAccounts(accounts: [], failures: failures))
    }

    private static func isWrongKeyEvidence(_ error: TokenProviderError) -> Bool {
        if case .decryptFailed(.decryptFailed) = error { return true }
        return false
    }

    /// Exponential backoff off the previous window (doubling), capped. A terminal
    /// (`distantFuture`) or absent window starts fresh at the default.
    static func nextBackoff(after stored: ThrottleState?, now _: Date) -> TimeInterval {
        guard let until = stored?.backoffUntil, let last = stored?.lastAttemptAt,
              until != .distantFuture, until > last
        else {
            return defaultBackoffSeconds
        }
        return min(maxBackoffSeconds, until.timeIntervalSince(last) * 2)
    }

    /// `sha256(token)[:16]` — a stable, non-secret identifier; a login switch changes it,
    /// invalidating the cached backoff immediately.
    static func fingerprint(_ token: String) -> String {
        let hex = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

private extension ResolvedAccount {
    /// Build an `AccountUsage` serving a stored sample (if any) with the given state.
    func usage(_ latest: UsageSample?, state: UsageState) -> AccountUsage {
        AccountUsage(identity: identity, snapshot: latest?.snapshot, state: state, bindingIDs: bindingIDs)
    }

    /// Merge a `/profile` identity in.
    ///
    /// A **hinted** account keeps its own uuid: that hint *is* the account UUID, written by Claude
    /// itself, and every persistent row is already keyed on it — so it only adopts the naming
    /// fields. A **provisional** account adopts the uuid too: that authoritative answer is exactly
    /// what it was waiting for, and it stops being provisional.
    func named(by profile: AccountIdentity) -> ResolvedAccount {
        var updated = self
        updated.identity.email = profile.email
        updated.identity.displayName = profile.displayName
        updated.identity.organizationUuid = identity.organizationUuid ?? profile.organizationUuid
        updated.identity.subscriptionType = identity.subscriptionType ?? profile.subscriptionType
        updated.identity.rateLimitTier = identity.rateLimitTier ?? profile.rateLimitTier
        if isProvisionalIdentity {
            updated.identity.uuid = profile.uuid
            updated.isProvisionalIdentity = false
        }
        return updated
    }
}

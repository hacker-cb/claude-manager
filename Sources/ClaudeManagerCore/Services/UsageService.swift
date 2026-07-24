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
    /// Non-private: the identity half lives in `UsageService+Identity` (another file), and both
    /// halves talk to the same client and store.
    let client: AnthropicOAuthClient
    private let keyStore: SafeStorageKeyStore
    let history: UsageHistoryStore
    let marketingVersion: String

    /// Minimum seconds between per-account fetches — also throttles a mashed manual Refresh.
    public static let floorSeconds: TimeInterval = 60
    /// Backoff applied to a 429 with no `Retry-After`, or the first transport/error backoff.
    public static let defaultBackoffSeconds: TimeInterval = 300
    /// Backoff ceiling — errors grow the window but never past this.
    public static let maxBackoffSeconds: TimeInterval = 1800
    /// `Retry-After` is clamped into this range.
    public static let retryAfterRange: ClosedRange<TimeInterval> = 60 ... 3600
    /// The adaptive fast lane: while a profile is running, polls no slower than this.
    public static let adaptiveFloorSeconds: TimeInterval = 5 * 60
    /// Background cadence when the user hasn't chosen one. The settings picker offers this
    /// among its presets, so the two can't disagree about what "default" means.
    public static let defaultPollMinutes = 30
    /// How long a stored `/profile` answer is trusted. A re-login invalidates it immediately
    /// (the fingerprint changes), so this only covers what can change *under the same token* —
    /// a renamed account, a changed email, a moved plan — at one call per account per day.
    public static let profileTTLSeconds: TimeInterval = 24 * 3600

    /// Throttle scope for the **usage** call: per account, since `/usage` answers per account and
    /// N launchers sharing a login must share one window.
    static func usageScope(_ accountUUID: String) -> String {
        accountUUID
    }

    /// Throttle scope for the **identity** call: per *token*, because that is the only key that
    /// exists before `/profile` answers. Keeping it apart from the usage scope is what stops a
    /// `/profile` rejection from silently cancelling the `/usage` call for the same account, and
    /// what lets a hint-less binding be gated at all — its account uuid isn't known yet, so a
    /// usage-scoped lookup would miss every row that account has ever written.
    static func identityScope(_ fingerprint: String) -> String {
        "identity:\(fingerprint)"
    }

    /// Seconds until the next poll for a given interval. `minutes` (floored at 1) in seconds,
    /// dropped to the adaptive 5-min lane while a profile is running — bounded by the interval
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
        // The master switch cancels this pass's task on toggle-off, and every phase below reads a
        // keychain token or calls the network — so cancellation is checked before each, not only
        // before `/usage`. Resolving already-past a check still reads tokens, but the pass then
        // fetches nothing and writes nothing, which is what "off stops all polling" (README /
        // SECURITY.md) promises for the work that has and hasn't happened yet.
        if Task.isCancelled { return UsageRefreshResult(accounts: [], bindingFailures: [:]) }
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
        // spent N calls and stored N rows for it. Gated on cancellation so a toggle-off during
        // resolution stops before spending any `/profile` call.
        if Task.isCancelled { return UsageRefreshResult(accounts: [], bindingFailures: resolved.failures) }
        let named = await identified(resolved.accounts, now: now, interactive: interactive)
        let settled = resolver.regroup(named, now: now)

        // Cancellation is checked between accounts so the master switch can actually stop a pass
        // in flight. Without it, turning tracking off part-way through a fleet still issued the
        // remaining calls and still wrote their rows — which the README and SECURITY.md promise
        // it does not.
        var accounts: [AccountUsage] = []
        for account in settled {
            if Task.isCancelled { break }
            await accounts.append(usage(for: account, now: now, interactive: interactive))
        }
        return UsageRefreshResult(accounts: accounts, bindingFailures: resolved.failures)
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
        let fingerprint = token.fingerprint
        let cutoff = now.addingTimeInterval(-Self.profileTTLSeconds)
        let named = await history.profile(tokenFingerprint: fingerprint, fetchedAfter: cutoff) != nil
        var account = resolved

        var uuid = account.identity.uuid
        let stored = await history.throttle(scope: Self.usageScope(uuid))
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
        //
        // Skipped entirely when a terminal park was just lifted: that `lastAttemptAt` was written
        // by the rejection being cleared, so honouring it here would swallow the retry the user
        // asked for — and answer with a falsely current state.
        let lifted = stored.map { Self.clearsTerminal($0, fingerprint, interactive) } ?? false
        if !lifted, let last = stored?.lastAttemptAt, now.timeIntervalSince(last) < Self.floorSeconds {
            return account.usage(latest, state: .fresh)
        }

        // Past every gate, so a `/usage` call is happening regardless: this is the moment to
        // refresh a missing or expired name too, which keeps the `/profile` call inside the same
        // backoff and floor that protect `/usage` instead of firing on every throttled tick.
        // Through the same gate as the identity pass: without it this retry re-asked a token the
        // pass had just seen rejected, so a dead login still cost two `/profile` calls per tick.
        if !named, await mayCall(account, fingerprint: fingerprint, now: now, interactive: interactive) {
            account = await fetchIdentity(account, fingerprint: fingerprint, now: now)
            // A late answer can settle a still-provisional account onto its real uuid, and every
            // write below must follow it — keyed on the stale binding id, the sample and throttle
            // land where the next tick never looks, orphaning the row and losing the floor.
            uuid = account.identity.uuid
        }

        let outcome = await client.fetchUsage(
            token: token.token,
            marketingVersion: marketingVersion,
            capturedAt: now
        )
        // The master switch can cancel the task *inside* the fetch above (a cancelled URLSession
        // call surfaces as `.transport`). The app discards this pass via its generation check, but
        // persistence must stop too: writing a sample or a backoff row here would land in usage.db
        // after "off", and an offline-backoff row would then serve the account stale on re-enable.
        // The between-accounts check can't see a cancellation that lands within this one fetch.
        if Task.isCancelled { return account.usage(latest, state: .fresh) }
        switch outcome {
        case let .success(fetch):
            let sample = UsageSample(
                accountUUID: uuid, capturedAt: now, snapshot: fetch.snapshot,
                source: "desktop:\(token.bindingID)"
            )
            await history.record(sample, rawBody: fetch.rawBody)
            await history.setThrottle(
                ThrottleState(lastAttemptAt: now, backoffUntil: nil, tokenFingerprint: fingerprint),
                scope: Self.usageScope(uuid)
            )
            return AccountUsage(
                identity: account.identity, snapshot: fetch.snapshot, state: .fresh,
                bindingIDs: account.bindingIDs
            )
        case let .failure(error):
            return await handleFailure(error, account: account, context: context)
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
            scope: Self.usageScope(uuid)
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
}

extension ResolvedAccount {
    /// Build an `AccountUsage` serving a stored sample (if any) with the given state.
    func usage(_ latest: UsageSample?, state: UsageState) -> AccountUsage {
        AccountUsage(identity: identity, snapshot: latest?.snapshot, state: state, bindingIDs: bindingIDs)
    }

    /// Merge a `/profile` identity in.
    ///
    /// `/profile` is authoritative about *which account this token belongs to*, so its uuid
    /// replaces the provisional fingerprint the account carried until now. The token's own coarse
    /// fields (org, plan, tier) still win where it has them; only the naming fields and the uuid
    /// come from `/profile`.
    func named(by profile: AccountIdentity) -> ResolvedAccount {
        var updated = self
        updated.identity.email = profile.email
        updated.identity.displayName = profile.displayName
        updated.identity.organizationUuid = identity.organizationUuid ?? profile.organizationUuid
        updated.identity.subscriptionType = identity.subscriptionType ?? profile.subscriptionType
        updated.identity.rateLimitTier = identity.rateLimitTier ?? profile.rateLimitTier
        // The authoritative account uuid replaces the token's fingerprint placeholder, so every
        // sample and notification is filed under the real account — and two tokens that turn out to
        // be different accounts keep their distinct uuids, never folding in `regroup`.
        updated.identity.uuid = profile.uuid
        return updated
    }
}

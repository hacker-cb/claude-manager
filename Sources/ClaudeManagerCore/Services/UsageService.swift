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

        var accounts: [AccountUsage] = []
        for account in resolved.accounts {
            await accounts.append(usage(for: account, now: now))
        }
        return UsageRefreshResult(accounts: accounts, bindingFailures: resolved.failures)
    }

    // MARK: - Per account

    private func usage(for resolved: ResolvedAccount, now: Date) async -> AccountUsage {
        let token = resolved.token
        // Expired token → call nothing at all (not even `/profile`, which would 401); the account
        // needs a fresh login. Served from whatever key we have.
        if token.isExpired(now: now) {
            let stale = await history.latest(accountUUID: resolved.identity.uuid)
            return resolved.usage(stale, state: .loginNeeded)
        }

        // Settle the identity *before* anything persistent is keyed on it. Without a local hint
        // the key would be the binding id, which flips the moment Claude writes
        // `lastKnownAccountUuid` (orphaning the throttle window and every stored sample) and
        // can't tell two same-org accounts apart. One `/profile` call fixes both — and fills in
        // the email / display name the UI otherwise never learns.
        let account = resolved.isProvisionalIdentity ? await reconcileIdentity(resolved) : resolved

        let uuid = account.identity.uuid
        let fingerprint = Self.fingerprint(token.token)
        let stored = await history.throttle(accountUUID: uuid)
        let latest = await history.latest(accountUUID: uuid)
        // A login switch (new token) clears any standing backoff — try immediately.
        let tokenChanged = stored?.tokenFingerprint != nil && stored?.tokenFingerprint != fingerprint
        // Standing backoff still active → serve stale, rendering the *original* cause (a
        // transport backoff must not read back as a 429).
        if !tokenChanged, let until = stored?.backoffUntil, until > now {
            let state: UsageState = switch stored?.backoffReason {
            case .terminal: .loginNeeded
            case .rateLimited: .rateLimited(until: until)
            case .offline, .none: latest.map { .stale(since: $0.capturedAt) } ?? .offline
            }
            return account.usage(latest, state: state)
        }
        // 60s floor since the last attempt → skip, serve what we have.
        if !tokenChanged, let last = stored?.lastAttemptAt, now.timeIntervalSince(last) < Self.floorSeconds {
            return account.usage(latest, state: latest.map { .stale(since: $0.capturedAt) } ?? .noSource)
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
            let context = PollContext(now: now, fingerprint: fingerprint, stored: stored, latest: latest)
            return await handleFailure(error, account: account, context: context)
        }
    }

    /// Ask `/profile` for the authoritative account UUID (plus email / display name) when no
    /// local hint identified the account. Any failure keeps the provisional identity — a later
    /// poll retries, and usage still works, just keyed per binding until it succeeds. Only ever
    /// reached for a binding whose `config.json` carries no `lastKnownAccountUuid`, which for a
    /// signed-in Desktop account is a transient state, so the extra call is not a per-tick cost
    /// for the normal fleet.
    private func reconcileIdentity(_ account: ResolvedAccount) async -> ResolvedAccount {
        let fetched = await client.fetchProfile(
            token: account.token.token,
            marketingVersion: marketingVersion
        )
        guard case let .success(profile) = fetched else { return account }
        var updated = account
        updated.identity.uuid = profile.accountUUID
        updated.identity.email = profile.email
        updated.identity.displayName = profile.displayName
        // The token's own values win — they're exact where `/profile` only exposes coarse flags.
        updated.identity.organizationUuid = account.identity.organizationUuid ?? profile.organizationUUID
        updated.identity.subscriptionType = account.identity.subscriptionType ?? profile.subscriptionType
        updated.identity.rateLimitTier = account.identity.rateLimitTier ?? profile.rateLimitTier
        updated.isProvisionalIdentity = false
        return updated
    }

    /// The per-account state a failure handler needs, bundled to keep the parameter list small.
    private struct PollContext {
        let now: Date
        let fingerprint: String
        let stored: ThrottleState?
        let latest: UsageSample?
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
        let backoffUntil: Date
        let reason: BackoffReason
        let state: UsageState

        switch error {
        case .unauthorized:
            // Terminal for this token: stop polling until the fingerprint changes (re-login)
            // or a manual refresh. A far-future backoff parks it; a new token clears it.
            backoffUntil = .distantFuture
            reason = .terminal
            state = .loginNeeded
        case let .rateLimited(retryAfter):
            let seconds = retryAfter.map { $0.clamped(to: Self.retryAfterRange) }
                ?? Self.nextBackoff(after: stored, now: now)
            backoffUntil = now.addingTimeInterval(seconds)
            reason = .rateLimited
            state = .rateLimited(until: backoffUntil)
        case .transport:
            backoffUntil = now.addingTimeInterval(Self.nextBackoff(after: stored, now: now))
            reason = .offline
            state = .offline
        case .httpError, .malformedBody:
            backoffUntil = now.addingTimeInterval(Self.nextBackoff(after: stored, now: now))
            reason = .offline
            state = latest.map { .stale(since: $0.capturedAt) } ?? .offline
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

    /// Whole-fleet rotation signal. The safeStorage key is **shared**, so a genuine `.decryptFailed`
    /// (padding rejected) proves *the key* is wrong — and since it's shared, wrong for every
    /// binding, making the sibling `.malformedCache` results wrong-key garbage too. So: nothing
    /// resolved, at least one definitive `.decryptFailed`, and every failure is crypto-related
    /// (decrypt / malformed) — not a `.configUnreadable`/`.noTokenCache` per-account problem.
    ///
    /// The "at least one `.decryptFailed`" guard is what excludes codex's case: if every binding
    /// decrypts fine but the *payload* is malformed (all `.malformedCache`, no `.decryptFailed`),
    /// the key is correct and invalidating it would mask the real bug and re-prompt for nothing.
    private static func shouldSelfHeal(_ resolved: ResolvedAccounts) -> Bool {
        guard resolved.accounts.isEmpty, !resolved.failures.isEmpty else { return false }
        let failures = resolved.failures.values
        return failures.contains(where: isDecryptFailure)
            && failures.allSatisfy { isDecryptFailure($0) || isMalformedCache($0) }
    }

    private static func isDecryptFailure(_ error: TokenProviderError) -> Bool {
        if case .decryptFailed = error { return true }
        return false
    }

    private static func isMalformedCache(_ error: TokenProviderError) -> Bool {
        if case .malformedCache = error { return true }
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
}

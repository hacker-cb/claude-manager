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

    private func usage(for account: ResolvedAccount, now: Date) async -> AccountUsage {
        let uuid = account.identity.uuid
        let token = account.token
        let fingerprint = Self.fingerprint(token.token)
        let stored = await history.throttle(accountUUID: uuid)
        let latest = await history.latest(accountUUID: uuid)
        // A login switch (new token) clears any standing backoff — try immediately.
        let tokenChanged = stored?.tokenFingerprint != nil && stored?.tokenFingerprint != fingerprint

        // Expired token → don't call; the account needs a fresh login.
        if token.isExpired(now: now) {
            return account.usage(latest, state: .loginNeeded)
        }
        // Standing backoff (429 / terminal / error) still active → serve stale.
        if !tokenChanged, let until = stored?.backoffUntil, until > now {
            let state: UsageState = until == .distantFuture ? .loginNeeded : .rateLimited(until: until)
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
        let state: UsageState

        switch error {
        case .unauthorized:
            // Terminal for this token: stop polling until the fingerprint changes (re-login)
            // or a manual refresh. A far-future backoff parks it; a new token clears it.
            backoffUntil = .distantFuture
            state = .loginNeeded
        case let .rateLimited(retryAfter):
            let seconds = retryAfter.map { $0.clamped(to: Self.retryAfterRange) }
                ?? Self.nextBackoff(after: stored, now: now)
            backoffUntil = now.addingTimeInterval(seconds)
            state = .rateLimited(until: backoffUntil)
        case .transport:
            backoffUntil = now.addingTimeInterval(Self.nextBackoff(after: stored, now: now))
            state = .offline
        case .httpError, .malformedBody:
            backoffUntil = now.addingTimeInterval(Self.nextBackoff(after: stored, now: now))
            state = latest.map { .stale(since: $0.capturedAt) } ?? .offline
        }

        await history.setThrottle(
            ThrottleState(lastAttemptAt: now, backoffUntil: backoffUntil, tokenFingerprint: fingerprint),
            accountUUID: uuid
        )
        return account.usage(latest, state: state)
    }

    // MARK: - Helpers

    /// Whole-fleet rotation signal: nothing resolved, and every failure was a decrypt failure
    /// (a stale shared key), not a per-account problem — safe to invalidate the key and retry.
    private static func shouldSelfHeal(_ resolved: ResolvedAccounts) -> Bool {
        resolved.accounts.isEmpty && !resolved.failures.isEmpty
            && resolved.failures.values.allSatisfy(isDecryptFailure)
    }

    private static func isDecryptFailure(_ error: TokenProviderError) -> Bool {
        switch error {
        case .decryptFailed, .malformedCache: true
        default: false
        }
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

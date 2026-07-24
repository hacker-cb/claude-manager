import Foundation

/// Why an OAuth usage/profile call didn't yield data.
public enum OAuthClientError: Error, Equatable, Sendable {
    /// 401/403 — the token is rejected. **Terminal** for that account: stop polling and show
    /// "login needed" until the token fingerprint changes or the user forces a refresh.
    case unauthorized(status: Int)
    /// 429 — backed off. `retryAfter` is honored when the server sends it (seconds or an
    /// HTTP-date), else the caller applies its default.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case httpError(status: Int)
    /// Transport failure (offline, timeout, DNS) — retryable with backoff.
    case transport
    /// 2xx but the body didn't parse into the expected shape.
    case malformedBody
}

/// A successful `/usage` fetch: the parsed snapshot plus the raw body, so the caller can both
/// render it and persist the raw JSON for the inspector / forward-compat.
public struct UsageFetch: Sendable, Equatable {
    public var snapshot: UsageSnapshot
    public var rawBody: Data

    public init(snapshot: UsageSnapshot, rawBody: Data) {
        self.snapshot = snapshot
        self.rawBody = rawBody
    }
}

/// Account identity from `/profile` — the authoritative account UUID + email, merged with the
/// token-derived fields by the resolver. All optional except the UUID so a partial body is
/// still usable.
public struct ProfileInfo: Sendable, Equatable {
    public var accountUUID: String
    public var email: String?
    public var displayName: String?
    public var organizationUUID: String?
    public var rateLimitTier: String?
    public var subscriptionType: String?

    public init(
        accountUUID: String,
        email: String? = nil,
        displayName: String? = nil,
        organizationUUID: String? = nil,
        rateLimitTier: String? = nil,
        subscriptionType: String? = nil
    ) {
        self.accountUUID = accountUUID
        self.email = email
        self.displayName = displayName
        self.organizationUUID = organizationUUID
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
    }
}

/// The Anthropic first-party OAuth client for plan-usage. The single place the usage/profile
/// endpoints, their pinned header set, and the 401/403/429 policy live. Injectable `HTTPClient`
/// so every path is unit-tested without a real request.
public struct AnthropicOAuthClient: Sendable {
    private let http: HTTPClient
    private let parser = UsageLimitsParser()

    /// 5s, matching the CLI's own `/usage` timeout.
    public static let timeout: TimeInterval = 5

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The pinned request headers. `anthropic-beta` is required; `anthropic-version` is not
    /// (a live call returns 200 without it). No secret beyond the bearer.
    static func headers(token: String, marketingVersion: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": CoreConstants.oauthBetaHeaderValue,
            "User-Agent": "ClaudeManager/\(marketingVersion)"
        ]
    }

    public func fetchUsage(
        token: String,
        marketingVersion: String,
        capturedAt: Date? = nil
    ) async -> Result<UsageFetch, OAuthClientError> {
        let url = usageURL(CoreConstants.usageAPIUsagePath)
        return await request(url: url, token: token, marketingVersion: marketingVersion) { body in
            guard let snapshot = parser.parse(body, capturedAt: capturedAt) else {
                return .failure(.malformedBody)
            }
            return .success(UsageFetch(snapshot: snapshot, rawBody: body))
        }
    }

    public func fetchProfile(
        token: String,
        marketingVersion: String
    ) async -> Result<ProfileInfo, OAuthClientError> {
        let url = usageURL(CoreConstants.usageAPIProfilePath)
        return await request(url: url, token: token, marketingVersion: marketingVersion) { body in
            guard let profile = Self.parseProfile(body) else { return .failure(.malformedBody) }
            return .success(profile)
        }
    }

    // MARK: - Request / status mapping

    private func request<T>(
        url: URL,
        token: String,
        marketingVersion: String,
        onSuccess: (Data) -> Result<T, OAuthClientError>
    ) async -> Result<T, OAuthClientError> {
        let response: HTTPResponse
        do {
            response = try await http.get(
                url: url,
                headers: Self.headers(token: token, marketingVersion: marketingVersion),
                timeout: Self.timeout
            )
        } catch {
            return .failure(.transport)
        }

        switch response.status {
        case 200 ..< 300:
            return onSuccess(response.body)
        case 401, 403:
            return .failure(.unauthorized(status: response.status))
        case 429:
            return .failure(.rateLimited(retryAfter: Self.parseRetryAfter(response.header("retry-after"))))
        default:
            return .failure(.httpError(status: response.status))
        }
    }

    private func usageURL(_ path: String) -> URL {
        // Constants are compile-time and known-valid; a force-unwrap here is a build-time
        // guarantee, not runtime input.
        URL(string: CoreConstants.usageAPIBaseURL + path)!
    }

    /// `Retry-After` is either a non-negative integer (seconds) or an HTTP-date; both are
    /// supported. Anything else → nil (caller uses its default backoff).
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            // `Retry-After: 0` means "retry right away". Honor it (>= 0, not > 0) so the caller's
            // floor — not the 5-minute default backoff — governs; a negative value is malformed.
            return seconds >= 0 ? TimeInterval(seconds) : nil
        }
        guard let date = httpDate(value) else { return nil }
        let interval = date.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    // MARK: - /profile parsing (defensive)

    static func parseProfile(_ data: Data) -> ProfileInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let uuid = account["uuid"] as? String
        else {
            return nil
        }
        let organization = root["organization"] as? [String: Any]
        return ProfileInfo(
            accountUUID: uuid,
            email: account["email"] as? String,
            displayName: account["display_name"] as? String,
            organizationUUID: organization?["uuid"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String,
            subscriptionType: subscriptionType(account: account, organization: organization)
        )
    }

    /// Derive a coarse plan from `/profile`. The token cache carries an exact
    /// `subscriptionType`; `/profile` only exposes `has_claude_max` / `has_claude_pro` and the
    /// org type, so map those. The resolver prefers the token's value when present.
    private static func subscriptionType(account: [String: Any], organization: [String: Any]?) -> String? {
        if account["has_claude_max"] as? Bool == true { return "max" }
        if account["has_claude_pro"] as? Bool == true { return "pro" }
        switch organization?["organization_type"] as? String {
        case "claude_max": return "max"
        case "claude_pro": return "pro"
        case let other?: return other
        case nil: return nil
        }
    }
}

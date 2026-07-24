import Foundation
import Testing
@testable import ClaudeManagerCore

struct AnthropicOAuthClientTests {
    private typealias Handler = @Sendable (URL, [String: String], TimeInterval) async throws -> HTTPResponse

    /// Closure-driven HTTP stub: returns a canned response or throws (transport failure).
    private struct MockHTTP: HTTPClient {
        let handler: Handler
        func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
            try await handler(url, headers, timeout)
        }
    }

    private func client(_ handler: @escaping Handler) -> AnthropicOAuthClient {
        AnthropicOAuthClient(http: MockHTTP(handler: handler))
    }

    private func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(json.utf8))
    }

    private let version = "1.2.3"

    // MARK: - Success

    @Test
    func parsesUsageOn200AndKeepsRawBody() async throws {
        let json = #"{"limits":[{"kind":"weekly_all","percent":40,"is_active":true}]}"#
        let result = await client { _, _, _ in ok(json) }
            .fetchUsage(token: "T", marketingVersion: version)
        let fetch = try result.get()
        #expect(fetch.snapshot.weeklyAll?.utilization == 0.40)
        #expect(fetch.rawBody == Data(json.utf8))
    }

    @Test
    func parsesProfileOn200() async throws {
        let json = """
        {"account":{"uuid":"acc-1","email":"x@y.me","display_name":"X","has_claude_max":true},
         "organization":{"uuid":"org-1","rate_limit_tier":"default_claude_max_20x","organization_type":"claude_max"}}
        """
        let profile = try await client { _, _, _ in ok(json) }
            .fetchProfile(token: "T", marketingVersion: version).get()
        #expect(profile.accountUUID == "acc-1")
        #expect(profile.email == "x@y.me")
        #expect(profile.organizationUUID == "org-1")
        #expect(profile.subscriptionType == "max")
        #expect(profile.rateLimitTier == "default_claude_max_20x")
    }

    // MARK: - Status mapping

    @Test
    func unauthorizedOn401And403() async {
        for status in [401, 403] {
            let result = await client { _, _, _ in HTTPResponse(status: status, body: Data()) }
                .fetchUsage(token: "T", marketingVersion: version)
            #expect(result == .failure(.unauthorized(status: status)))
        }
    }

    @Test
    func rateLimitedParsesRetryAfterSeconds() async {
        let result = await client { _, _, _ in
            HTTPResponse(status: 429, body: Data(), headers: ["retry-after": "120"])
        }.fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.rateLimited(retryAfter: 120)))
    }

    @Test
    func rateLimitedParsesMixedCaseRetryAfterHeader() async {
        // A producer that preserves server casing must still be honored.
        let result = await client { _, _, _ in
            HTTPResponse(status: 429, body: Data(), headers: ["Retry-After": "90"])
        }.fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.rateLimited(retryAfter: 90)))
    }

    @Test
    func rateLimitedWithoutHeaderHasNilRetryAfter() async {
        let result = await client { _, _, _ in HTTPResponse(status: 429, body: Data()) }
            .fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.rateLimited(retryAfter: nil)))
    }

    @Test
    func httpErrorOnOtherStatus() async {
        let result = await client { _, _, _ in HTTPResponse(status: 500, body: Data()) }
            .fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.httpError(status: 500)))
    }

    @Test
    func transportFailureOnThrow() async {
        let result = await client { _, _, _ in throw URLError(.notConnectedToInternet) }
            .fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.transport))
    }

    @Test
    func malformedBodyOn200NonJSON() async {
        let result = await client { _, _, _ in ok("not json") }
            .fetchUsage(token: "T", marketingVersion: version)
        #expect(result == .failure(.malformedBody))
    }

    // MARK: - Header pinning (proven set; no anthropic-version)

    @Test
    func headersArePinnedWithoutAnthropicVersion() {
        let headers = AnthropicOAuthClient.headers(token: "SECRET", marketingVersion: "9.9.9")
        #expect(headers["Authorization"] == "Bearer SECRET")
        #expect(headers["anthropic-beta"] == CoreConstants.oauthBetaHeaderValue)
        #expect(headers["User-Agent"] == "ClaudeManager/9.9.9")
        #expect(headers["anthropic-version"] == nil)
        #expect(Set(headers.keys) == ["Authorization", "anthropic-beta", "User-Agent"])
    }

    @Test
    func actuallySendsPinnedHeaders() async {
        // Capture what the client puts on the wire.
        let box = HeaderBox()
        _ = await client { _, headers, _ in
            box.set(headers)
            return ok("{}")
        }.fetchUsage(token: "SECRET", marketingVersion: "9.9.9")
        let sent = box.get()
        #expect(sent["Authorization"] == "Bearer SECRET")
        #expect(sent["anthropic-version"] == nil)
    }

    private final class HeaderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [String: String] = [:]
        func set(_ value: [String: String]) {
            lock.lock(); headers = value; lock.unlock()
        }

        func get() -> [String: String] {
            lock.lock(); defer { lock.unlock() }; return headers
        }
    }

    // MARK: - Retry-After parsing

    @Test
    func parseRetryAfterHandlesSecondsDateAndGarbage() {
        #expect(AnthropicOAuthClient.parseRetryAfter("120") == 120)
        #expect(AnthropicOAuthClient
            .parseRetryAfter("0") == 0) // "retry now" — caller's floor governs, not the 5-min default
        #expect(AnthropicOAuthClient.parseRetryAfter("-5") == nil)
        #expect(AnthropicOAuthClient.parseRetryAfter("nonsense") == nil)
        #expect(AnthropicOAuthClient.parseRetryAfter(nil) == nil)

        // HTTP-date, evaluated against a fixed now.
        let now = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09T01:46:40Z
        let httpDate = "Sun, 09 Sep 2001 01:48:40 GMT" // now + 120s
        let parsed = AnthropicOAuthClient.parseRetryAfter(httpDate, now: now)
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - 120) < 1)
        // A past HTTP-date yields nil (no negative backoff).
        #expect(AnthropicOAuthClient.parseRetryAfter("Sun, 09 Sep 2001 01:44:40 GMT", now: now) == nil)
    }
}

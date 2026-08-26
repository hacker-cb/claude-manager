import Foundation
import Testing
@testable import ClaudeManagerCore

struct UpdateFeedTests {
    private typealias Handler = @Sendable (URL, [String: String], TimeInterval) async throws -> HTTPResponse

    /// Closure-driven HTTP stub: returns a canned response or throws (transport failure).
    private struct MockHTTP: HTTPClient {
        let handler: Handler
        func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
            try await handler(url, headers, timeout)
        }
    }

    private func feed(_ handler: @escaping Handler) -> UpdateFeed {
        UpdateFeed(client: MockHTTP(handler: handler), endpoint: Self.endpoint)
    }

    private static let endpoint = URL(string: "https://example.invalid/zip/latest")!

    /// Verbatim body of a real `zip/latest` response, so the parser is pinned to the shape
    /// the endpoint actually returns rather than one this test invented.
    private static let liveSample = """
    {"version":"1.37937.1","url":"https://downloads.claude.ai/releases/darwin/universal/\
    1.37937.1/Claude-edbd3c346a2ffba6e653c9e861724f4260f5e749.zip"}
    """

    private func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(json.utf8))
    }

    // MARK: - Parsing

    @Test
    func parsesTheLivePayloadShape() async throws {
        let update = try await feed { _, _, _ in ok(Self.liveSample) }.latest()
        #expect(update.version == "1.37937.1")
        #expect(update.downloadURL.absoluteString.hasSuffix(
            "/1.37937.1/Claude-edbd3c346a2ffba6e653c9e861724f4260f5e749.zip"
        ))
    }

    /// The endpoint is undocumented, so it may grow fields at any time; gaining one must
    /// not turn into "no updates available" for everybody.
    @Test
    func ignoresUnknownFields() throws {
        let update = try UpdateFeed.parse(Data("""
        {"version":"2.0.0","url":"https://example.invalid/a.zip","sha256":"abc","size":1,"channel":"beta"}
        """.utf8))
        #expect(update.version == "2.0.0")
    }

    @Test(arguments: [
        #"{"url":"https://example.invalid/a.zip"}"#, // no version
        #"{"version":"2.0.0"}"#, // no url
        #"{"version":"","url":"https://example.invalid/a.zip"}"#, // empty version
        #"{"version":2,"url":"https://example.invalid/a.zip"}"#, // version not a string
        #"{"version":"v1.40000.0","url":"https://example.invalid/a.zip"}"#, // not dotted-numeric
        #"{"version":"1.notnumeric.0","url":"https://example.invalid/a.zip"}"#,
        #"{"version":"1..0","url":"https://example.invalid/a.zip"}"#, // empty component
        #"{"version":" 1.2.3","url":"https://example.invalid/a.zip"}"#, // padded
        #"{"version":"1.2.3\n","url":"https://example.invalid/a.zip"}"#, // trailing newline
        #"{"version":"١.٢.٣","url":"https://example.invalid/a.zip"}"#, // non-ASCII digits
        #"{"version":"2.0.0","url":"not a url at all"}"#, // unparseable url
        #"{"version":"2.0.0","url":"https:///a.zip"}"#, // no host
        "[]", // not an object
        "" // not JSON
    ])
    func rejectsMalformedPayloads(_ body: String) {
        #expect(throws: UpdateFeed.Failure.malformedPayload) {
            try UpdateFeed.parse(Data(body.utf8))
        }
    }

    /// Everything downstream — the signature check included — assumes these bytes crossed
    /// TLS. A plaintext or `file:` URL is refused rather than quietly downgraded.
    @Test(arguments: [
        "http://downloads.claude.ai/a.zip",
        "file:///tmp/a.zip",
        "ftp://downloads.claude.ai/a.zip",
    ])
    func refusesDownloadsThatAreNotHTTPS(_ url: String) {
        #expect(throws: UpdateFeed.Failure.insecureDownloadURL) {
            try UpdateFeed.parse(Data(#"{"version":"2.0.0","url":"\#(url)"}"#.utf8))
        }
    }

    /// A scheme is case-insensitive per RFC 3986; rejecting `HTTPS://` would be a bug, not
    /// strictness.
    @Test
    func acceptsAnUppercasedScheme() throws {
        let update = try UpdateFeed.parse(Data(
            #"{"version":"2.0.0","url":"HTTPS://downloads.claude.ai/a.zip"}"#.utf8
        ))
        // Asserted on the parsed components, not on `absoluteString`: Foundation is free to
        // normalise the scheme's case, and pinning the literal would make this test about
        // Foundation's spelling rather than about the URL being accepted.
        #expect(update.downloadURL.scheme?.lowercased() == "https")
        #expect(update.downloadURL.host == "downloads.claude.ai")
    }

    // MARK: - Transport

    @Test(arguments: [204, 400, 403, 404, 500, 503])
    func surfacesANonOKStatus(_ status: Int) async {
        let feed = feed { _, _, _ in HTTPResponse(status: status, body: Data("{}".utf8)) }
        await #expect(throws: UpdateFeed.Failure.unexpectedStatus(status)) { try await feed.latest() }
    }

    /// Being offline is not "no update available" — it has to stay distinguishable, so the
    /// transport error passes through instead of being folded into a `Failure`.
    @Test
    func letsTransportFailuresThrough() async {
        let feed = feed { _, _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await feed.latest() }
    }

    @Test
    func requestsTheConfiguredEndpoint() async throws {
        let seen = Mailbox<URL>()
        let feed = feed { url, _, _ in
            await seen.put(url)
            return ok(Self.liveSample)
        }
        _ = try await feed.latest()
        #expect(await seen.take() == Self.endpoint)
    }

    @Test
    func passesTheRequestedTimeoutThrough() async throws {
        let seen = Mailbox<TimeInterval>()
        let feed = feed { _, _, timeout in
            await seen.put(timeout)
            return ok(Self.liveSample)
        }
        _ = try await feed.latest(timeout: 3)
        #expect(await seen.take() == 3)
    }

    // MARK: - Upgrade comparison

    @Test(arguments: [
        ("1.37937.1", "1.30096.5", true), // newer
        ("1.30096.5", "1.37937.1", false), // older — a rollback is never an upgrade
        ("1.37937.1", "1.37937.1", false), // same build
        ("1.37937.2", "1.37937.1", true), // patch bump
        ("1.9.0", "1.10.0", false), // numeric, not lexicographic
        ("garbage", "1.37937.1", false) // unparseable never reads as newer
    ])
    func comparesAgainstTheInstalledVersion(_ offered: String, _ installed: String, _ expected: Bool) {
        let update = AvailableUpdate(version: offered, downloadURL: Self.endpoint)
        #expect(update.isUpgrade(over: installed) == expected)
    }

    /// An unreadable `/Applications/Claude.app` leaves no baseline to improve on, and
    /// "upgrade" would license replacing a working install with an unknown build.
    @Test
    func doesNotClaimAnUpgradeWithoutABaseline() {
        let update = AvailableUpdate(version: "1.37937.1", downloadURL: Self.endpoint)
        #expect(!update.isUpgrade(over: nil))
    }

    /// The dangerous half of the same guard, and the one `nil` does not cover.
    /// `RealClaude.version()` reads the plist with `as? String`, so a bundle caught
    /// mid-write hands back `""` rather than `nil` — and an all-zeroes baseline makes
    /// *every* release look like an upgrade, which is exactly backwards for a decision that
    /// replaces `/Applications/Claude.app`.
    @Test(arguments: ["", "   ", "unknown", "v1.37937.1", "1.x.0"])
    func doesNotClaimAnUpgradeOverAnUnparseableBaseline(_ installed: String) {
        let update = AvailableUpdate(version: "1.37937.1", downloadURL: Self.endpoint)
        #expect(!update.isUpgrade(over: installed))
    }

    /// The https guard is the only trust boundary in this slice, so it is worth one case
    /// that goes through the real entry point rather than the parser alone.
    @Test
    func refusesAnInsecureDownloadThroughLatest() async {
        let feed = feed { _, _, _ in
            ok(#"{"version":"2.0.0","url":"http://downloads.claude.ai/a.zip"}"#)
        }
        await #expect(throws: UpdateFeed.Failure.insecureDownloadURL) { try await feed.latest() }
    }
}

/// One-slot async box for capturing what a stub was called with, without `nonisolated(unsafe)`
/// mutable state in the test.
private actor Mailbox<Value: Sendable> {
    private var value: Value?
    func put(_ newValue: Value) {
        value = newValue
    }

    func take() -> Value? {
        value
    }
}
